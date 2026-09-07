-module(erlite_catalog_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         three_member_catalog_status/1, join_and_leave_catalog_member/1,
         database_lifecycle_is_durable_and_fenced/1]).

all() -> [three_member_catalog_status, join_and_leave_catalog_member,
          database_lifecycle_is_durable_and_fenced].

init_per_suite(Config) ->
    Root = filename:join("/tmp", "erlite-catalog-" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
    {ok, _} = ra:start([{data_dir, Root}]),
    {ok, Router} = erlite_database_router:start_link(),
    unlink(Router),
    [{root, Root}, {router, Router} | Config].

end_per_suite(Config) ->
    lists:foreach(fun(ServerId) ->
                          _ = ra:force_delete_server(default, ServerId)
                  end, router_group_ids() ++
                       [catalog_server_4() | server_ids()]),
    ok = gen_server:stop(proplists:get_value(router, Config)),
    ok = application:unset_env(erlite_core, catalog_server),
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

database_lifecycle_is_durable_and_fenced(_Config) ->
    [ServerRef | _] = server_ids(),
    DatabaseId = <<"catalog-database">>,
    CreateOp = <<10:128>>,
    DeleteOp = <<11:128>>,
    Replicas = [{erlite_catalog_db_1, node()},
                {erlite_catalog_db_2, node()},
                {erlite_catalog_db_3, node()}],
    ok = erlite_catalog:prepare_database_create(
           ServerRef, DatabaseId, CreateOp, 1, Replicas, 10000),
    ok = erlite_database_router:configure(ServerRef),
    {error, {database_not_ready, creating}} =
        erlite_database_router:resolve(DatabaseId, 10000),
    {ok, #{state := creating, generation := 1,
           operation_id := CreateOp, replicas := Replicas}} =
        erlite_catalog:database(ServerRef, DatabaseId, 10000, consistent),
    {ok, [#{database_id := DatabaseId}]} =
        erlite_catalog:recoverable_databases(ServerRef, 10000, consistent),
    ok = erlite_catalog:mark_database_ready(
           ServerRef, DatabaseId, CreateOp, 1, 10000),
    {ok, _Started, []} = ra:start_cluster(
                           default, <<"catalog-router-target">>,
                           {simple, fun(_Command, State) -> State end, #{}},
                           Replicas),
    {ok, #{state := ready}} =
        erlite_database_router:resolve(DatabaseId, 10000),
    _ = sys:get_state(whereis(erlite_database_router)),
    {ok, #{database := #{database_id := DatabaseId}, leader := Leader}} =
        erlite_database_router:leader(DatabaseId, 10000),
    true = lists:member(Leader, Replicas),
    _ = sys:get_state(whereis(erlite_database_router)),
    {ok, #{generation := 1, leader := Leader}} =
        erlite_database_router:cached(DatabaseId),
    {error, {stale_generation, 2, 1}} =
        erlite_catalog:prepare_database_delete(
          ServerRef, DatabaseId, DeleteOp, 2, 10000),
    ok = erlite_catalog:prepare_database_delete(
           ServerRef, DatabaseId, DeleteOp, 1, 10000),
    {error, {database_not_ready, deleting}} =
        erlite_database_router:resolve(DatabaseId, 10000),
    _ = sys:get_state(whereis(erlite_database_router)),
    {error, route_not_cached} = erlite_database_router:cached(DatabaseId),
    ok = erlite_catalog:tombstone_database(
           ServerRef, DatabaseId, DeleteOp, 1, 10000),
    {ok, #{state := tombstoned}} =
        erlite_catalog:database(ServerRef, DatabaseId, 10000, consistent),
    ok.

catalog_nodes() ->
    [#{node_id => <<N:128>>, node_name => integer_to_binary(N),
       server_id => ServerId}
     || {N, ServerId} <- lists:zip([1, 2, 3], server_ids())].

server_ids() ->
    [{Name, node()} || Name <- [erlite_catalog_1, erlite_catalog_2,
                                erlite_catalog_3]].

catalog_server_4() -> {erlite_catalog_4, node()}.

router_group_ids() ->
    [{erlite_catalog_db_1, node()}, {erlite_catalog_db_2, node()},
     {erlite_catalog_db_3, node()}].

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
