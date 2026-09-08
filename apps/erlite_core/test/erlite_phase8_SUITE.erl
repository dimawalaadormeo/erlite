-module(erlite_phase8_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         automatic_repair_and_stale_return_cleanup/1]).

all() -> [automatic_repair_and_stale_return_cleanup].

init_per_suite(Config) ->
    case node() of
        nonode@nohost -> {skip, requires_distributed_test_node};
        _ -> start_cluster(Config)
    end.

start_cluster(Config) ->
    Root = filename:join(
             "/tmp", "erlite-phase8-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    Specs = [{erlite_p8_a, 1}, {erlite_p8_b, 2},
             {erlite_p8_c, 3}, {erlite_p8_d, 4}],
    Peers = [start_peer(Name, Number, Root) || {Name, Number} <- Specs],
    [{_, Node1, _}, {_, Node2, _}, {_, Node3, _}, {_, Node4, _}] = Peers,
    {ok, CatalogServers, []} = erlite_catalog:start(
                                 crypto:strong_rand_bytes(16),
                                 <<"phase8-test">>,
                                 catalog_nodes([Node1, Node2, Node3])),
    Catalog = lists:nth(2, CatalogServers),
    true = is_atom(Node4),
    persistent_term:put({?MODULE, peers}, Peers),
    ok = application:set_env(erlite_core, repair_grace_period_ms, 0),
    ok = application:set_env(erlite_core, repair_scan_interval_ms, 600000),
    {ok, Sup} = erlite_core_sup:start_link(),
    unlink(Sup),
    ok = erlite_database_lifecycle:configure(Catalog, Root),
    ok = erlite_replica_repair:configure(Catalog, Root),
    [{root, Root}, {peers, Peers}, {supervisor, Sup},
     {catalog, Catalog} | Config].

end_per_suite(Config) ->
    case proplists:get_value(supervisor, Config) of
        Sup when is_pid(Sup) -> _ = gen_server:stop(Sup, normal, 5000);
        _ -> ok
    end,
    [stop_peer(Peer) || {Peer, _Node, _Number} <-
                            persistent_term:get({?MODULE, peers}, [])],
    persistent_term:erase({?MODULE, peers}),
    application:unset_env(erlite_core, repair_grace_period_ms),
    application:unset_env(erlite_core, repair_scan_interval_ms),
    cleanup(proplists:get_value(root, Config, "/tmp/erlite-no-phase8-root")),
    ok.

automatic_repair_and_stale_return_cleanup(Config) ->
    Root = proplists:get_value(root, Config),
    Catalog = proplists:get_value(catalog, Config),
    Peers = proplists:get_value(peers, Config),
    {FailedPeer, FailedNode, FailedNumber} = hd(Peers),
    {_SparePeer, SpareNode, _SpareNumber} = lists:nth(4, Peers),
    DatabaseId = <<"phase8-automatic-repair">>,
    ok = erlite_database_lifecycle:create(DatabaseId),
    ok = seed_and_write(DatabaseId),
    {ok, #{generation := 1, replicas := Replicas}} =
        erlite_catalog:database(Catalog, DatabaseId, 15000, consistent),
    [Failed] = [ServerId || ServerId = {_, Node} <- Replicas,
                            Node =:= FailedNode],

    ok = stop_peer(FailedPeer),
    ok = await_repair_marked(Catalog, DatabaseId, Failed, 15000),
    {ok, Waiting = #{generation := 1,
                     repair := #{phase := waiting, failed := Failed}}} =
        erlite_catalog:database(Catalog, DatabaseId, 15000, consistent),
    false = maps:is_key(movement, Waiting),
    {ok, MembersBefore, _} = ra:members(Replicas, 15000),
    3 = length(MembersBefore),
    {error, {repair_scan_failed, [{error, no_repair_target}]}} =
        erlite_replica_repair:scan(),

    ok = join_catalog_node(Catalog, SpareNode, 4),
    ok = erlite_replica_repair:scan(),
    {ok, Repaired = #{generation := 2, replicas := NewReplicas,
                      stale_replicas := [#{server_id := Failed}]}} =
        erlite_catalog:database(Catalog, DatabaseId, 15000, consistent),
    false = maps:is_key(repair, Repaired),
    false = maps:is_key(movement, Repaired),
    false = lists:member(Failed, NewReplicas),
    true = lists:any(fun({_, Node}) -> Node =:= SpareNode end, NewReplicas),
    {ok, NewMembers, _} = ra:members(NewReplicas, 15000),
    true = lists:sort(NewReplicas) =:= lists:sort(NewMembers),
    {ok, #{rows := [[<<"preserved">>]]}} = erlite_databases:query(
                                               DatabaseId,
                                               <<"SELECT value FROM repaired">>,
                                               [], 15000),

    {NewFailedPeer, FailedNode, FailedNumber} =
        start_peer(erlite_p8_a, FailedNumber, Root),
    replace_peer(FailedPeer, NewFailedPeer, FailedNode, FailedNumber),
    ok = erlite_replica_repair:scan(),
    {ok, Clean} = erlite_catalog:database(
                    Catalog, DatabaseId, 15000, consistent),
    false = maps:is_key(stale_replicas, Clean),
    undefined = rpc:call(FailedNode, ra_directory, where_is,
                         [default, element(1, Failed)]),
    ok.

await_repair_marked(Catalog, DatabaseId, Failed, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_repair_marked(Catalog, DatabaseId, Failed, Deadline, undefined).

await_repair_marked(_Catalog, _DatabaseId, Failed, _Deadline,
                    {ok, #{repair := #{phase := waiting,
                                      failed := Failed}}}) -> ok;
await_repair_marked(Catalog, DatabaseId, Failed, Deadline, Last) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail({repair_scan_timeout, Last});
        false ->
            _ = erlite_replica_repair:scan(),
            timer:sleep(50),
            Result = erlite_catalog:database(
                       Catalog, DatabaseId, 15000, consistent),
            await_repair_marked(Catalog, DatabaseId, Failed, Deadline, Result)
    end.

start_peer(Name, Number, Root) ->
    {ok, Peer, Node} = peer:start_link(#{name => Name}),
    unlink(Peer),
    ok = rpc:call(Node, code, add_paths, [code:get_path()]),
    {ok, _} = rpc:call(Node, application, ensure_all_started, [erlite_sqlite]),
    RaRoot = filename:join([Root, integer_to_list(Number), "raft"]),
    {ok, _} = rpc:call(Node, ra, start, [[{data_dir, RaRoot}]]),
    Incoming = filename:join([Root, integer_to_list(Number), "incoming"]),
    ok = rpc:call(Node, application, set_env,
                  [erlite_raft, incoming_snapshot_root, Incoming]),
    {Peer, Node, Number}.

replace_peer(OldPeer, NewPeer, Node, Number) ->
    Peers = persistent_term:get({?MODULE, peers}),
    persistent_term:put(
      {?MODULE, peers},
      [{NewPeer, Node, Number} | [Entry || Entry = {Peer, _, _} <- Peers,
                                          Peer =/= OldPeer]]),
    ok.

seed_and_write(DatabaseId) ->
    [{DatabaseId, Controller}] = ets:lookup(erlite_database_routes, DatabaseId),
    #{replicas := Owners} = sys:get_state(Controller),
    lists:foreach(
      fun(Owner) ->
              {ok, _} = erlite_sqlite_owner:execute(
                          Owner,
                          <<"CREATE TABLE repaired (value TEXT NOT NULL)">>, [])
      end, maps:values(Owners)),
    {ok, Command} = erlite_raft_command:new_transaction(
                      <<"phase8-write">>, 0,
                      [{<<"INSERT INTO repaired(value) VALUES(?)">>,
                        [<<"preserved">>]}]),
    {ok, _} = erlite_databases:write(DatabaseId, Command, 15000),
    ok.

join_catalog_node(Catalog, Node, Number) ->
    erlite_catalog:join(
      Catalog,
      #{node_id => <<Number:128>>, node_name => atom_to_binary(Node),
        server_id => {erlite_catalog, Node}}, 15000).

catalog_nodes(Nodes) ->
    [#{node_id => <<Number:128>>, node_name => atom_to_binary(Node),
       server_id => {erlite_catalog, Node}}
     || {Node, Number} <- lists:zip(Nodes, [1, 2, 3])].

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
