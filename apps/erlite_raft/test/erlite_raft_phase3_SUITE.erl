-module(erlite_raft_phase3_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         single_database_high_availability/1]).

all() -> [single_database_high_availability].

init_per_suite(Config) ->
    case node() of
        nonode@nohost -> {skip, requires_distributed_test_node};
        _ -> start_peers(Config)
    end.

start_peers(Config) ->
    Root = filename:join(
             "/tmp", "erlite-phase3-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    PeerSpecs = [{erlite_p3_a, 1}, {erlite_p3_b, 2}, {erlite_p3_c, 3}],
    PeersAndNodes = [begin
                         {ok, Peer, Node} = peer:start_link(#{name => Name}),
                         erlang:unlink(Peer),
                         {Peer, Node, Number}
                     end || {Name, Number} <- PeerSpecs],
    Paths = code:get_path(),
    lists:foreach(
      fun({_Peer, Node, Number}) ->
              ok = rpc:call(Node, code, add_paths, [Paths]),
              {ok, _} = rpc:call(
                          Node, application, ensure_all_started,
                          [erlite_sqlite]),
              RaDir = filename:join(
                        [Root, integer_to_list(Number), "raft"]),
              {ok, _} = rpc:call(Node, ra, start, [[{data_dir, RaDir}]]),
              ok = rpc:call(Node, application, start, [erlite_raft])
      end, PeersAndNodes),
    [{root, Root}, {peers_and_nodes, PeersAndNodes} | Config].

end_per_suite(Config) ->
    lists:foreach(
      fun({Peer, _Node, _Number}) -> stop_peer(Peer) end,
      proplists:get_value(peers_and_nodes, Config, [])),
    cleanup(proplists:get_value(root, Config, "/tmp/erlite-no-phase3-root")),
    ok.

single_database_high_availability(Config) ->
    Triples = proplists:get_value(peers_and_nodes, Config),
    Nodes = [Node || {_Peer, Node, _Number} <- Triples],
    Members = [{erlite_phase3, Node} || Node <- Nodes],
    Root = proplists:get_value(root, Config),
    DatabaseId = <<"phase3-database">>,
    Replicas = maps:from_list(
                 [create_replica(Root, Number, Node, DatabaseId, ServerId)
                  || {{_Peer, Node, Number}, ServerId} <-
                         lists:zip(Triples, Members)]),
    {ok, RuntimeIdentity} = erlite_sqlite_owner:runtime_identity(
                              maps:get(hd(Members), Replicas)),
    {ok, Started, []} = rpc:call(
                          hd(Nodes), erlite_raft_cluster, start,
                          [<<"erlite_phase3_test">>, Members,
                           RuntimeIdentity]),
    Members = lists:sort(Started),

    {ok, _} = erlite_raft_database:write(
                Members, command(<<"tx-1">>, 1, <<"one">>), Replicas, 15000),
    [{ok, ready, _} = erlite_raft_database:readiness(
                         Members, Replicas, Member, 15000)
     || Member <- Members],
    {ok, CompatibilityBarrier, _} = erlite_raft_cluster:barrier(
                                      Members, 15000),
    DifferentRuntime = RuntimeIdentity#{sqlite_version => <<"different">>},
    {error, {incompatible_sqlite_runtime, _, _}} =
        erlite_raft_applier:catch_up(
          hd(Members), maps:get(hd(Members), Replicas),
          CompatibilityBarrier#{runtime_identity => DifferentRuntime}, 15000),

    {ok, _Barrier1, Leader1} = erlite_raft_cluster:barrier(Members, 15000),
    Follower = hd(Members -- [Leader1]),
    ok = stop_server(Follower),
    {ok, _} = erlite_raft_database:write(
                Members -- [Follower], command(<<"tx-2">>, 2, <<"two">>),
                Replicas, 15000),
    ok = restart_server(Follower),
    {ok, ready, _} = erlite_raft_database:readiness(
                       Members, Replicas, Follower, 15000),

    ok = stop_server(Leader1),
    {ok, _} = erlite_raft_database:write(
                Members -- [Leader1], command(<<"tx-3">>, 3, <<"three">>),
                Replicas, 15000),
    {ok, #{rows := [[3]]}} = erlite_raft_database:consistent_read(
                                Members -- [Leader1],
                                <<"SELECT count(*) FROM items">>, [],
                                Replicas, 15000),
    ok = restart_server(Leader1),
    {ok, ready, _} = erlite_raft_database:readiness(
                       Members, Replicas, Leader1, 15000),

    {ok, DelayedIndex, _} = erlite_raft_cluster:submit(
                              Members, command(<<"tx-4">>, 4, <<"four">>),
                              15000),
    DelayedReplica = hd(Members),
    {ok, ready, AppliedIndex} = erlite_raft_database:readiness(
                                  Members, Replicas, DelayedReplica, 15000),
    true = AppliedIndex >= DelayedIndex,

    SnapshotRoots = maps:from_list(
                      [{ServerId,
                        filename:join([Root, integer_to_list(Number),
                                       "snapshots"])}
                       || {{_Peer, _Node, Number}, ServerId} <-
                              lists:zip(Triples, Members)]),
    {ok, DelayedIndex, _Manifests} = erlite_raft_database:checkpoint(
                                       Members, Replicas, SnapshotRoots,
                                       DatabaseId, 1, 0, 15000),
    {error, {snapshot_required, _}} = await_snapshot_required(
                                        hd(Members), 0, 15000),
    {ok, _} = erlite_raft_database:write(
                Members, command(<<"tx-1">>, 1, <<"one">>), Replicas, 15000),
    {error, {transaction_id_conflict, <<"tx-1">>}} =
        erlite_raft_database:write(
          Members, command(<<"tx-1">>, 10, <<"different">>),
          Replicas, 15000),
    {ok, #{rows := [[4]]}} = erlite_raft_database:consistent_read(
                                Members, <<"SELECT count(*) FROM items">>, [],
                                Replicas, 15000),

    {ok, _Barrier2, CurrentLeader} = erlite_raft_cluster:barrier(Members, 15000),
    [Minority1, Minority2] = Members -- [CurrentLeader],
    ok = stop_server(Minority1),
    ok = stop_server(Minority2),
    NoQuorumCommand = command(<<"tx-no-quorum">>, 99, <<"no">>),
    QuorumWrite = erlite_raft_database:write(
                    CurrentLeader, NoQuorumCommand, Replicas, 1000),
    false = is_success(QuorumWrite),
    QuorumRead = erlite_raft_database:consistent_read(
                   CurrentLeader, <<"SELECT count(*) FROM items">>, [],
                   Replicas, 1000),
    false = is_success(QuorumRead),
    ok = restart_server(Minority1),
    {ok, _} = erlite_raft_database:write(
                [CurrentLeader, Minority1],
                command(<<"tx-5">>, 5, <<"five">>), Replicas, 15000),
    {ok, _} = erlite_raft_database:write(
                [CurrentLeader, Minority1], NoQuorumCommand, Replicas, 15000),
    %% The timed-out command may commit after quorum returns; timeout is an
    %% ambiguous result, never permission to submit a different transaction
    %% under the same transaction id.
    {ok, #{rows := [[6]]}} = erlite_raft_database:consistent_read(
                                [CurrentLeader, Minority1],
                                <<"SELECT count(*) FROM items">>, [],
                                Replicas, 15000),
    ok = restart_server(Minority2),
    [{ok, ready, _} = erlite_raft_database:readiness(
                         Members, Replicas, Member, 15000)
     || Member <- Members],
    ok.

create_replica(Root, Number, Node, DatabaseId, ServerId) ->
    DbRoot = filename:join([Root, integer_to_list(Number), "database"]),
    ok = rpc:call(Node, erlite_sqlite_databases, create, [DbRoot, DatabaseId]),
    {ok, Owner} = rpc:call(
                    Node, erlite_sqlite_databases, open, [DbRoot, DatabaseId]),
    {ok, _} = erlite_sqlite_owner:execute(
                Owner,
                <<"CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)">>,
                []),
    {ServerId, Owner}.

stop_server({_, Node} = ServerId) ->
    rpc:call(Node, ra, stop_server, [default, ServerId]).

restart_server({_, Node} = ServerId) ->
    rpc:call(Node, ra, restart_server, [default, ServerId]).

await_snapshot_required(ServerId, Index, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_snapshot_required(ServerId, Index, Deadline, undefined).

await_snapshot_required(ServerId, Index, Deadline, _LastResult) ->
    Result = erlite_raft_cluster:committed_entries_after(ServerId, Index, 1000),
    case Result of
        {error, {snapshot_required, _}} -> Result;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> Result;
                false ->
                    timer:sleep(25),
                    await_snapshot_required(ServerId, Index, Deadline, Result)
            end
    end.

is_success({ok, _}) -> true;
is_success({ok, _, _}) -> true;
is_success(_) -> false.

command(TransactionId, Id, Value) ->
    {ok, Command} = erlite_raft_command:new_transaction(
                      TransactionId, 0,
                      [{<<"INSERT INTO items (id, value) VALUES (?, ?)">>,
                        [Id, Value]}]),
    Command.

stop_peer(Peer) ->
    try peer:stop(Peer) of
        ok -> ok
    catch
        exit:_ -> ok
    end.

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end,
                          Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
