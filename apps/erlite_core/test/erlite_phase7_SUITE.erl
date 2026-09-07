-module(erlite_phase7_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         expand_three_to_four_and_move/1,
         expand_four_to_six_and_move/1,
         movement_reconciles_membership_crash_points/1]).

all() -> [expand_three_to_four_and_move,
          expand_four_to_six_and_move,
          movement_reconciles_membership_crash_points].

init_per_suite(Config) ->
    case node() of
        nonode@nohost -> {skip, requires_distributed_test_node};
        _ -> start_cluster(Config)
    end.

start_cluster(Config) ->
    Root = filename:join(
             "/tmp", "erlite-phase7-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    PeerSpecs = [{erlite_p7_a, 1}, {erlite_p7_b, 2}, {erlite_p7_c, 3},
                 {erlite_p7_d, 4}, {erlite_p7_e, 5}, {erlite_p7_f, 6}],
    Peers = [begin
                 {ok, Peer, Node} = peer:start_link(#{name => Name}),
                 unlink(Peer),
                 {Peer, Node, Number}
             end || {Name, Number} <- PeerSpecs],
    Paths = code:get_path(),
    lists:foreach(
      fun({_Peer, Node, Number}) ->
              ok = rpc:call(Node, code, add_paths, [Paths]),
              {ok, _} = rpc:call(Node, application, ensure_all_started,
                                 [erlite_sqlite]),
              RaRoot = filename:join(
                         [Root, integer_to_list(Number), "raft"]),
              {ok, _} = rpc:call(Node, ra, start, [[{data_dir, RaRoot}]]),
              Incoming = filename:join(
                           [Root, integer_to_list(Number), "incoming"]),
              ok = rpc:call(Node, application, set_env,
                            [erlite_raft, incoming_snapshot_root, Incoming])
      end, Peers),
    [{_, Node1, _}, {_, Node2, _}, {_, Node3, _} | _] = Peers,
    InitialNodes = catalog_nodes([Node1, Node2, Node3], 1),
    {ok, CatalogServers, []} = erlite_catalog:start(
                                 crypto:strong_rand_bytes(16),
                                 <<"phase7-test">>, InitialNodes),
    {ok, Sup} = erlite_core_sup:start_link(),
    unlink(Sup),
    ok = erlite_database_lifecycle:configure(hd(CatalogServers), Root),
    [{root, Root}, {peers, Peers}, {supervisor, Sup},
     {catalog, hd(CatalogServers)} | Config].

end_per_suite(Config) ->
    case proplists:get_value(supervisor, Config) of
        Sup when is_pid(Sup) -> _ = gen_server:stop(Sup, normal, 5000);
        _ -> ok
    end,
    [stop_peer(Peer) || {Peer, _Node, _Number} <-
                            proplists:get_value(peers, Config, [])],
    cleanup(proplists:get_value(root, Config, "/tmp/erlite-no-phase7-root")),
    ok.

expand_three_to_four_and_move(Config) ->
    Catalog = proplists:get_value(catalog, Config),
    [{_, _Node1, _}, {_, _Node2, _}, {_, _Node3, _},
     {_, Node4, _} | _] = proplists:get_value(peers, Config),
    ok = ensure_catalog_node(Catalog, Node4, 4),
    DatabaseId = <<"phase7-three-to-four">>,
    ok = erlite_database_lifecycle:create(DatabaseId),
    {ok, Before = #{generation := 1, replicas := Replicas}} =
        erlite_catalog:database(Catalog, DatabaseId, 15000, consistent),
    false = lists:any(fun({_, Node}) -> Node =:= Node4 end, Replicas),
    Source = hd(Replicas),
    ok = seed_and_write(DatabaseId),
    ok = erlite_database_lifecycle:move(DatabaseId, Source, Node4),
    {ok, After = #{generation := 2, replicas := NewReplicas}} =
        erlite_catalog:database(Catalog, DatabaseId, 15000, consistent),
    false = maps:is_key(movement, After),
    false = lists:member(Source, NewReplicas),
    true = lists:any(fun({_, Node}) -> Node =:= Node4 end, NewReplicas),
    {ok, Members, _Leader} = ra:members(NewReplicas, 15000),
    true = lists:sort(NewReplicas) =:= lists:sort(Members),
    {ok, #{rows := [[<<"preserved">>]]}} = erlite_databases:query(
                                               DatabaseId,
                                               <<"SELECT value FROM moved">>,
                                               [], 15000),
    3 = maps:get(replication_factor, Before),
    kill_controller(DatabaseId),
    ok = erlite_database_lifecycle:delete(DatabaseId),
    {ok, #{state := tombstoned}} = erlite_catalog:database(
                                      Catalog, DatabaseId, 15000, consistent),
    ok.

expand_four_to_six_and_move(Config) ->
    Catalog = proplists:get_value(catalog, Config),
    Peers = proplists:get_value(peers, Config),
    {_, Node5, _} = lists:nth(5, Peers),
    {_, Node6, _} = lists:nth(6, Peers),
    ok = join_catalog_node(Catalog, Node5, 5),
    ok = join_catalog_node(Catalog, Node6, 6),
    DatabaseId = <<"phase7-four-to-six">>,
    ok = erlite_database_lifecycle:create(DatabaseId),
    {ok, #{replicas := Initial}} = erlite_catalog:database(
                                      Catalog, DatabaseId, 15000, consistent),
    [Source1, Source2 | _] = Initial,
    ok = seed_and_write(DatabaseId),
    ok = erlite_database_lifecycle:move(DatabaseId, Source1, Node5),
    {ok, #{replicas := Middle}} = erlite_catalog:database(
                                     Catalog, DatabaseId, 15000, consistent),
    ActualSource2 = case lists:member(Source2, Middle) of
                        true -> Source2;
                        false -> hd(Middle)
                    end,
    ok = erlite_database_lifecycle:move(DatabaseId, ActualSource2, Node6),
    {ok, #{generation := 3, replicas := Final}} = erlite_catalog:database(
                                                    Catalog, DatabaseId,
                                                    15000, consistent),
    true = lists:any(fun({_, Node}) -> Node =:= Node5 end, Final),
    true = lists:any(fun({_, Node}) -> Node =:= Node6 end, Final),
    {ok, #{rows := [[<<"preserved">>]]}} = erlite_databases:query(
                                               DatabaseId,
                                               <<"SELECT value FROM moved">>,
                                               [], 15000),
    ok.

movement_reconciles_membership_crash_points(Config) ->
    Catalog = proplists:get_value(catalog, Config),
    {_, Node4, _} = lists:nth(4, proplists:get_value(peers, Config)),
    ok = ensure_catalog_node(Catalog, Node4, 4),
    crash_after_prepare(Catalog, Node4),
    crash_after_add(Catalog, Node4),
    crash_after_remove(Catalog, Node4),
    ok.

crash_after_prepare(Catalog, TargetNode) ->
    DatabaseId = <<"phase7-crash-after-prepare">>,
    {Source, Replacement, Generation, OperationId} =
        prepare_test_move(Catalog, DatabaseId, TargetNode, prepare),
    true = is_tuple(Source),
    true = is_tuple(Replacement),
    restart_lifecycle(),
    await_move_complete(Catalog, DatabaseId, Generation + 1, 30000),
    true = is_binary(OperationId).

crash_after_add(Catalog, TargetNode) ->
    DatabaseId = <<"phase7-crash-after-add">>,
    {Source, Replacement, Generation, _OperationId} =
        prepare_test_move(Catalog, DatabaseId, TargetNode, add),
    ok = erlite_databases:add_replacement(
           DatabaseId, Source, Replacement, Generation, 15000),
    kill_controller(DatabaseId),
    restart_lifecycle(),
    await_move_complete(Catalog, DatabaseId, Generation + 1, 30000).

crash_after_remove(Catalog, TargetNode) ->
    DatabaseId = <<"phase7-crash-after-remove">>,
    {Source, Replacement, Generation, OperationId} =
        prepare_test_move(Catalog, DatabaseId, TargetNode, remove),
    ok = erlite_databases:add_replacement(
           DatabaseId, Source, Replacement, Generation, 15000),
    ok = erlite_catalog:mark_database_replacement_ready(
           Catalog, DatabaseId, OperationId, Generation, 15000),
    ok = erlite_databases:remove_source(
           DatabaseId, Source, Replacement, 15000),
    kill_controller(DatabaseId),
    restart_lifecycle(),
    await_move_complete(Catalog, DatabaseId, Generation + 1, 30000).

prepare_test_move(Catalog, DatabaseId, TargetNode, Suffix) ->
    ok = erlite_database_lifecycle:create(DatabaseId),
    ok = seed_and_write(DatabaseId),
    {ok, #{generation := Generation, replicas := Replicas}} =
        erlite_catalog:database(Catalog, DatabaseId, 15000, consistent),
    Source = hd(Replicas),
    OperationId = crypto:strong_rand_bytes(16),
    Replacement = {list_to_atom("erlite_phase7_" ++ atom_to_list(Suffix) ++
                                "_replacement"), TargetNode},
    ok = erlite_catalog:prepare_database_move(
           Catalog, DatabaseId, OperationId, Generation, Source, Replacement,
           15000),
    {Source, Replacement, Generation, OperationId}.

restart_lifecycle() ->
    OldPid = whereis(erlite_database_lifecycle),
    exit(OldPid, kill),
    await_lifecycle_restart(OldPid, 5000).

kill_controller(DatabaseId) ->
    [{DatabaseId, Controller}] = ets:lookup(
                                  erlite_database_routes, DatabaseId),
    exit(Controller, kill),
    await_route_removed(DatabaseId, 5000).

await_route_removed(DatabaseId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_route_removed(DatabaseId, Deadline,
                        ets:lookup(erlite_database_routes, DatabaseId)).

await_route_removed(_DatabaseId, _Deadline, []) -> ok;
await_route_removed(DatabaseId, Deadline, _Entry) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail(controller_route_not_removed);
        false ->
            timer:sleep(10),
            await_route_removed(
              DatabaseId, Deadline,
              ets:lookup(erlite_database_routes, DatabaseId))
    end.

await_lifecycle_restart(OldPid, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_lifecycle_restart(OldPid, Deadline, whereis(erlite_database_lifecycle)).

await_lifecycle_restart(OldPid, _Deadline, Pid)
  when is_pid(Pid), Pid =/= OldPid -> ok;
await_lifecycle_restart(OldPid, Deadline, _Pid) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail(lifecycle_did_not_restart);
        false ->
            timer:sleep(10),
            await_lifecycle_restart(
              OldPid, Deadline, whereis(erlite_database_lifecycle))
    end.

await_move_complete(Catalog, DatabaseId, Generation, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_move_complete(Catalog, DatabaseId, Generation, Deadline, undefined).

await_move_complete(_Catalog, _DatabaseId, Generation, _Deadline,
                    {ok, #{generation := Generation} = Database}) ->
    false = maps:is_key(movement, Database),
    ok;
await_move_complete(Catalog, DatabaseId, Generation, Deadline, _Last) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail(move_reconciliation_timeout);
        false ->
            timer:sleep(25),
            Result = erlite_catalog:database(
                       Catalog, DatabaseId, 15000, consistent),
            await_move_complete(Catalog, DatabaseId, Generation, Deadline,
                                Result)
    end.

seed_and_write(DatabaseId) ->
    [{DatabaseId, Controller}] = ets:lookup(erlite_database_routes, DatabaseId),
    #{replicas := Owners} = sys:get_state(Controller),
    lists:foreach(
      fun(Owner) ->
              {ok, _} = erlite_sqlite_owner:execute(
                          Owner,
                          <<"CREATE TABLE moved (value TEXT NOT NULL)">>, [])
      end, maps:values(Owners)),
    {ok, Command} = erlite_raft_command:new_transaction(
                      <<"phase7-write">>, 0,
                      [{<<"INSERT INTO moved(value) VALUES(?)">>,
                        [<<"preserved">>]}]),
    {ok, _Index} = erlite_databases:write(DatabaseId, Command, 15000),
    ok.

join_catalog_node(Catalog, Node, Number) ->
    Record = #{node_id => <<Number:128>>,
               node_name => atom_to_binary(Node),
               server_id => {erlite_catalog, Node}},
    erlite_catalog:join(Catalog, Record, 15000).

ensure_catalog_node(Catalog, Node, Number) ->
    case erlite_catalog:status(Catalog, 15000, consistent) of
        {ok, #{nodes := Nodes}} ->
            case lists:any(
                   fun(#{state := active, server_id := {_, ExistingNode}}) ->
                           ExistingNode =:= Node;
                      (_) -> false
                   end, Nodes) of
                true -> ok;
                false -> join_catalog_node(Catalog, Node, Number)
            end;
        Error -> Error
    end.

catalog_nodes(Nodes, Start) ->
    [#{node_id => <<Number:128>>, node_name => atom_to_binary(Node),
       server_id => {erlite_catalog, Node}}
     || {Node, Number} <- lists:zip(
                            Nodes, lists:seq(Start, Start + length(Nodes) - 1))].

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
