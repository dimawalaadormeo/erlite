-module(erlite_cluster_three_node_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         bootstrap_join_and_restart/1]).

all() -> [bootstrap_join_and_restart].

init_per_suite(Config) ->
    case node() of
        nonode@nohost -> {skip, requires_distributed_test_node};
        _ -> start_peers(Config)
    end.

start_peers(Config) ->
    Root = filename:join("/tmp", "erlite-real-three-node-" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer1, Node1} = peer:start_link(#{name => erlite_p2_a}),
    {ok, Peer2, Node2} = peer:start_link(#{name => erlite_p2_b}),
    {ok, Peer3, Node3} = peer:start_link(#{name => erlite_p2_c}),
    lists:foreach(fun erlang:unlink/1, [Peer1, Peer2, Peer3]),
    Nodes = [Node1, Node2, Node3],
    Paths = code:get_path(),
    lists:foreach(
      fun({Node, N}) ->
              ok = rpc:call(Node, code, add_paths, [Paths]),
              {ok, _} = rpc:call(Node, application, ensure_all_started, [crypto]),
              RaDir = filename:join([Root, integer_to_list(N), "raft"]),
              {ok, _} = rpc:call(Node, ra, start, [[{data_dir, RaDir}]])
      end, lists:zip(Nodes, [1, 2, 3])),
    [{root, Root}, {peers, [Peer1, Peer2, Peer3]}, {nodes, Nodes} | Config].

end_per_suite(Config) ->
    [stop_peer(Peer) || Peer <- proplists:get_value(peers, Config, [])],
    cleanup(proplists:get_value(root, Config, "/tmp/erlite-no-test-root")),
    ok.

stop_peer(Peer) ->
    try peer:stop(Peer) of
        ok -> ok
    catch
        exit:_ -> ok
    end.

bootstrap_join_and_restart(Config) ->
    [Node1, Node2, Node3] = proplists:get_value(nodes, Config),
    Root = proplists:get_value(root, Config),
    Config1 = cluster_config(Root, 1, Node1),
    Config2 = cluster_config(Root, 2, Node2),
    Config3 = cluster_config(Root, 3, Node3),
    {ok, _} = rpc:call(Node1, erlite_cluster, init_cluster, [Config1]),
    Seed = {erlite_catalog, Node1},
    Release = rpc:call(Node1, erlite_release, metadata, []),
    Future = Release#{cluster_protocol => 3, min_cluster_protocol => 2},
    ok = rpc:call(Node1, erlite_release, set_test_metadata, [Future]),
    {error, incompatible_cluster_protocol} =
        rpc:call(Node2, erlite_cluster, join, [Seed, Config2, 15000]),
    {error, node_identity_not_found} = rpc:call(
                                         Node2, erlite_node_identity, load,
                                         [maps:get(storage_path, Config2)]),
    ok = rpc:call(Node1, erlite_release, clear_test_metadata, []),
    {ok, _} = rpc:call(Node2, erlite_cluster, join, [Seed, Config2, 15000]),
    {ok, Status} = rpc:call(Node3, erlite_cluster, join,
                            [Seed, Config3, 15000]),
    3 = length([Node || Node = #{state := active} <- maps:get(nodes, Status)]),
    3 = maps:get(replication_factor, Status),
    2 = maps:get(quorum, Status),
    Server3 = {erlite_catalog, Node3},
    ok = rpc:call(Node3, ra, stop_server, [default, Server3]),
    ok = rpc:call(Node3, ra, restart_server, [default, Server3]),
    {ok, RestartedStatus} = rpc:call(Node3, erlite_cluster, status,
                                     [maps:get(storage_path, Config3), 15000]),
    3 = length(maps:get(nodes, RestartedStatus)),
    {error, would_lose_catalog_quorum} =
        rpc:call(Node3, erlite_cluster, leave,
                 [maps:get(storage_path, Config3), 15000]),
    ok.

cluster_config(Root, Number, Node) ->
    #{storage_path => filename:join(Root, integer_to_list(Number)),
      node_name => atom_to_binary(Node),
      cluster_name => <<"real-phase2-test">>,
      replication_factor => 3,
      seed_nodes => []}.

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
