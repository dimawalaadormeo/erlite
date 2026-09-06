-module(erlite_catalog_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         three_member_catalog_status/1, join_and_leave_catalog_member/1]).

all() -> [three_member_catalog_status, join_and_leave_catalog_member].

init_per_suite(Config) ->
    Root = filename:join("/tmp", "erlite-catalog-" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
    {ok, _} = ra:start([{data_dir, Root}]),
    [{root, Root} | Config].

end_per_suite(Config) ->
    lists:foreach(fun(ServerId) ->
                          _ = ra:force_delete_server(default, ServerId)
                  end, [catalog_server_4() | server_ids()]),
    _ = application:stop(ra),
    cleanup(proplists:get_value(root, Config)),
    ok.

three_member_catalog_status(_Config) ->
    ClusterId = crypto:strong_rand_bytes(16),
    {ok, Started, []} = erlite_catalog:start(
                          ClusterId, <<"phase2-test">>, catalog_nodes()),
    {ok, Status} = erlite_catalog:status(hd(Started), 10000, consistent),
    3 = maps:get(replication_factor, Status),
    2 = maps:get(quorum, Status),
    ClusterId = maps:get(cluster_id, Status),
    3 = length(maps:get(nodes, Status)),
    ok.

join_and_leave_catalog_member(_Config) ->
    [ServerRef | _] = server_ids(),
    Joining = #{node_id => <<4:128>>, node_name => <<"4">>,
                server_id => catalog_server_4()},
    ok = erlite_catalog:join(ServerRef, Joining, 10000),
    {ok, JoinedStatus} = erlite_catalog:status(ServerRef, 10000, consistent),
    [#{state := active}] =
        [Node || Node <- maps:get(nodes, JoinedStatus),
                 maps:get(node_id, Node) =:= <<4:128>>],
    {ok, JoinedMembers, _} = ra:members(ServerRef, 10000),
    true = lists:member(catalog_server_4(), JoinedMembers),
    ok = erlite_catalog:leave(ServerRef, <<4:128>>, 10000),
    {ok, LeftStatus} = erlite_catalog:status(ServerRef, 10000, consistent),
    [] = [Node || Node <- maps:get(nodes, LeftStatus),
                  maps:get(node_id, Node) =:= <<4:128>>],
    {ok, LeftMembers, _} = ra:members(ServerRef, 10000),
    false = lists:member(catalog_server_4(), LeftMembers),
    ok.

catalog_nodes() ->
    [#{node_id => <<N:128>>, node_name => integer_to_binary(N),
       server_id => ServerId}
     || {N, ServerId} <- lists:zip([1, 2, 3], server_ids())].

server_ids() ->
    [{Name, node()} || Name <- [erlite_catalog_1, erlite_catalog_2,
                                erlite_catalog_3]].

catalog_server_4() -> {erlite_catalog_4, node()}.

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
