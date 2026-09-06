-module(erlite_cluster_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_is_restart_safe_and_status_is_consistent/1]).

all() -> [init_is_restart_safe_and_status_is_consistent].

init_per_suite(Config) ->
    Root = filename:join("/tmp", "erlite-cluster-api-" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    RaDir = filename:join(Root, "raft"),
    ok = filelib:ensure_dir(filename:join(RaDir, "placeholder")),
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = ra:start([{data_dir, RaDir}]),
    [{root, Root} | Config].

end_per_suite(Config) ->
    _ = ra:force_delete_server(default, {erlite_catalog, node()}),
    _ = application:stop(ra),
    cleanup(proplists:get_value(root, Config)),
    ok.

init_is_restart_safe_and_status_is_consistent(Config) ->
    Root = proplists:get_value(root, Config),
    ClusterConfig = #{storage_path => Root,
                      node_name => atom_to_binary(node()),
                      cluster_name => <<"api-test">>,
                      replication_factor => 3,
                      seed_nodes => []},
    {ok, First} = erlite_cluster:init_cluster(ClusterConfig),
    {ok, Metadata1} = erlite_cluster_metadata:load(Root),
    {ok, Second} = erlite_cluster:init_cluster(ClusterConfig),
    {ok, Metadata2} = erlite_cluster_metadata:load(Root),
    true = maps:get(cluster_id, First) =:= maps:get(cluster_id, Second),
    true = maps:get(cluster_id, Metadata1) =:= maps:get(cluster_id, Metadata2),
    {ok, Second} = erlite_cluster:status(Root, 10000),
    ok.

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
