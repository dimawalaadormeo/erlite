-module(erlite_database_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         multiple_database_lifecycle_and_isolation/1,
         catalog_lifecycle_reconciles_interrupted_work/1,
         external_api_query_transaction_and_control/1]).

all() -> [multiple_database_lifecycle_and_isolation,
          catalog_lifecycle_reconciles_interrupted_work,
          external_api_query_transaction_and_control].

init_per_suite(Config) ->
    Root = filename:join(
             "/tmp", "erlite-multiple-databases-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    RaDir = filename:join(Root, "raft"),
    ok = filelib:ensure_dir(filename:join(RaDir, "placeholder")),
    {ok, _} = application:ensure_all_started(erlite_sqlite),
    {ok, _} = ra:start([{data_dir, RaDir}]),
    ok = application:start(erlite_raft),
    {ok, Sup} = erlite_core_sup:start_link(),
    unlink(Sup),
    CatalogNodes = catalog_nodes(),
    {ok, CatalogServers, []} = erlite_catalog:start(
                                 crypto:strong_rand_bytes(16),
                                 <<"phase5-lifecycle-test">>, CatalogNodes),
    Catalog = hd(CatalogServers),
    ok = erlite_database_lifecycle:configure(Catalog, Root),
    [{root, Root}, {supervisor, Sup}, {catalog, Catalog},
     {catalog_servers, CatalogServers} | Config].

end_per_suite(Config) ->
    lists:foreach(fun(ServerId) ->
                          _ = ra:force_delete_server(default, ServerId)
                  end, lifecycle_server_ids() ++
                       proplists:get_value(catalog_servers, Config)),
    Sup = proplists:get_value(supervisor, Config),
    ok = gen_server:stop(Sup, normal, 5000),
    _ = application:stop(erlite_raft),
    _ = application:stop(ra),
    cleanup(proplists:get_value(root, Config)),
    ok.

catalog_lifecycle_reconciles_interrupted_work(Config) ->
    Catalog = proplists:get_value(catalog, Config),
    PublicDatabaseId = <<"phase5-public-api">>,
    ok = erlite_database_lifecycle:create(PublicDatabaseId),
    {ok, #{state := ready}} = erlite_catalog:database(
                                 Catalog, PublicDatabaseId, 15000, consistent),
    ok = erlite_database_lifecycle:delete(PublicDatabaseId),
    {ok, #{state := tombstoned}} = erlite_catalog:database(
                                      Catalog, PublicDatabaseId, 15000,
                                      consistent),
    DatabaseId = <<"phase5-recovery">>,
    CreateOp = <<51:128>>,
    DeleteOp = <<52:128>>,
    Replicas = lifecycle_server_ids(),
    ok = erlite_catalog:prepare_database_create(
           Catalog, DatabaseId, CreateOp, 1, Replicas, 15000),
    Root = proplists:get_value(root, Config),
    ok = erlite_sqlite_databases:create(
           filename:join([Root, "replicas", "1"]), DatabaseId),
    OldLifecycle = whereis(erlite_database_lifecycle),
    exit(OldLifecycle, kill),
    _NewLifecycle = await_process_restart(
                      erlite_database_lifecycle, OldLifecycle, 5000),
    ok = await_catalog_state(Catalog, DatabaseId, ready, 15000),
    {ok, [DatabaseId]} = erlite_databases:list(),
    ok = erlite_catalog:prepare_database_delete(
           Catalog, DatabaseId, DeleteOp, 1, 15000),
    ok = supervisor:terminate_child(erlite_database_sup, DatabaseId),
    {error, not_found} = supervisor:delete_child(
                           erlite_database_sup, DatabaseId),
    OldRegistry = whereis(erlite_databases),
    exit(OldRegistry, kill),
    _ = await_registry_restart(OldRegistry, 5000),
    {ok, []} = erlite_databases:list(),
    DeleteLifecycle = whereis(erlite_database_lifecycle),
    exit(DeleteLifecycle, kill),
    _ = await_process_restart(
          erlite_database_lifecycle, DeleteLifecycle, 5000),
    ok = await_catalog_state(Catalog, DatabaseId, tombstoned, 15000),
    {ok, []} = erlite_databases:list(),
    false = lists:any(
              fun(N) ->
                      {ok, Path} = erlite_sqlite_database:path(
                                     filename:join(
                                       [Root, "replicas", integer_to_list(N)]),
                                     DatabaseId),
                      filelib:is_file(Path)
              end, [1, 2, 3]),
    true = lists:all(
             fun({Name, _Node}) ->
                     undefined =:= ra_directory:where_is(default, Name)
             end, Replicas),
    ok = erlite_database_lifecycle:delete(DatabaseId),
    ok.

external_api_query_transaction_and_control(_Config) ->
    DatabaseId = <<"phase6-api">>,
    Admin = #{role => admin},
    Service = #{role => service, databases => [DatabaseId]},
    {200, _} = erlite_api_handler:handle(
                 <<"POST">>, <<"/v1/databases">>,
                 #{<<"database_id">> => DatabaseId}, Admin),
    {ok, Controller} = case ets:lookup(erlite_database_routes, DatabaseId) of
                           [{DatabaseId, Pid}] -> {ok, Pid};
                           [] -> {error, missing_controller}
                       end,
    #{replicas := Replicas} = sys:get_state(Controller),
    lists:foreach(
      fun(Owner) ->
              {ok, _} = erlite_sqlite_owner:execute(
                          Owner,
                          <<"CREATE TABLE products (sku TEXT PRIMARY KEY, "
                            "name TEXT NOT NULL)">>, [])
      end, maps:values(Replicas)),
    Transaction = #{<<"transaction_id">> => <<"api-write-1">>,
                    <<"statements">> =>
                        [#{<<"sql">> =>
                               <<"INSERT INTO products(sku,name) VALUES(?,?)">>,
                           <<"params">> => [<<"A1">>, <<"Widget">>]}]},
    {200, _} = erlite_api_handler:handle(
                 <<"POST">>, <<"/v1/databases/phase6-api/transactions">>,
                 Transaction, Service),
    {200, #{<<"result">> := #{<<"rows">> := [[<<"Widget">>]]}}} =
        erlite_api_handler:handle(
          <<"POST">>, <<"/v1/databases/phase6-api/query">>,
          #{<<"sql">> => <<"SELECT name FROM products WHERE sku = ?">>,
            <<"params">> => [<<"A1">>]}, Service),
    {403, _} = erlite_api_handler:handle(
                 <<"POST">>, <<"/v1/databases/phase6-api/query">>,
                 #{<<"sql">> => <<"SELECT 1">>},
                 #{role => service, databases => [<<"other">>]}),
    {200, _} = erlite_api_handler:handle(
                 <<"DELETE">>, <<"/v1/databases/phase6-api">>, #{}, Admin),
    ok.

multiple_database_lifecycle_and_isolation(Config) ->
    Root = proplists:get_value(root, Config),
    Db1 = <<"merchant-one">>,
    Db2 = <<"merchant-two">>,
    Members1 = [{erlite_multi_1a, node()}, {erlite_multi_1b, node()},
                {erlite_multi_1c, node()}],
    Members2 = [{erlite_multi_2a, node()}, {erlite_multi_2b, node()},
                {erlite_multi_2c, node()}],
    {ok, _} = erlite_databases:create(
                Db1, #{storage_root => Root, server_ids => Members1}),
    {ok, _} = erlite_databases:create(
                Db2, #{storage_root => Root, server_ids => Members2}),
    {ok, [Db1, Db2]} = erlite_databases:list(),
    {error, database_exists} = erlite_databases:create(
                                 Db1, #{storage_root => Root,
                                        server_ids => Members1}),
    {error, raft_server_id_in_use} = erlite_databases:create(
                                       <<"collision">>,
                                       #{storage_root => Root,
                                         server_ids => Members1}),
    {ok, Status1} = erlite_databases:status(Db1),
    active = maps:get(mode, Status1),
    3 = maps:get(raft_members, Status1),
    3 = maps:get(open_sqlite_replicas, Status1),
    true = maps:get(sqlite_bytes, Status1) > 0,
    true = maps:get(sqlite_bytes, Status1) =< 393216,
    true = maps:get(controller_memory_bytes, Status1) =< 262144,
    true = maps:get(sqlite_owner_memory_bytes, Status1) =< 1572864,
    true = maps:get(raft_server_memory_bytes, Status1) =< 3145728,
    ct:pal("Phase 4 active per-database resource measurement: ~p", [Status1]),
    OldRegistry = whereis(erlite_databases),
    exit(OldRegistry, kill),
    NewRegistry = await_registry_restart(OldRegistry, 5000),
    {ok, [Db1, Db2]} = erlite_databases:list(),
    {ok, _} = erlite_databases:status(Db1),
    ok = sys:suspend(NewRegistry),
    try
        {ok, _} = erlite_databases:status(Db2)
    after
        ok = sys:resume(NewRegistry)
    end,
    ok = erlite_databases:cool(Db1),
    {ok, ColdStatus} = erlite_databases:status(Db1),
    cold = maps:get(mode, ColdStatus),
    0 = maps:get(open_sqlite_replicas, ColdStatus),
    {ok, #{rows := [[2]]}} = erlite_databases:query(
                                Db1,
                                <<"SELECT count(*) FROM sqlite_schema "
                                  "WHERE name LIKE '__erlite_%'">>,
                                [], 15000),
    {ok, Reactivated} = erlite_databases:status(Db1),
    active = maps:get(mode, Reactivated),
    ok = erlite_databases:delete(Db1),
    {ok, [Db2]} = erlite_databases:list(),
    {error, database_not_found} = erlite_databases:status(Db1),
    {ok, _} = erlite_databases:status(Db2),
    ok = erlite_databases:delete(Db2),
    ok = erlite_databases:delete(Db2),
    {ok, []} = erlite_databases:list(),
    ok.

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end,
                          Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.

await_registry_restart(OldPid, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_registry_restart(OldPid, Deadline, whereis(erlite_databases)).

await_registry_restart(OldPid, _Deadline, Pid)
  when is_pid(Pid), Pid =/= OldPid -> Pid;
await_registry_restart(OldPid, Deadline, _Pid) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail(database_registry_did_not_restart);
        false ->
            timer:sleep(10),
            await_registry_restart(
              OldPid, Deadline, whereis(erlite_databases))
    end.

catalog_nodes() ->
    [#{node_id => <<N:128>>, node_name => integer_to_binary(N),
       server_id => ServerId}
     || {N, ServerId} <- lists:zip([41, 42, 43], catalog_server_ids())].

catalog_server_ids() ->
    [{Name, node()} || Name <- [erlite_lifecycle_catalog_1,
                                erlite_lifecycle_catalog_2,
                                erlite_lifecycle_catalog_3]].

lifecycle_server_ids() ->
    [{Name, node()} || Name <- [erlite_lifecycle_db_1,
                                erlite_lifecycle_db_2,
                                erlite_lifecycle_db_3]].

await_process_restart(Name, OldPid, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_process_restart(Name, OldPid, Deadline, whereis(Name)).

await_process_restart(_Name, OldPid, _Deadline, Pid)
  when is_pid(Pid), Pid =/= OldPid -> Pid;
await_process_restart(Name, OldPid, Deadline, _Pid) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail({process_did_not_restart, Name});
        false ->
            timer:sleep(10),
            await_process_restart(Name, OldPid, Deadline, whereis(Name))
    end.

await_catalog_state(Catalog, DatabaseId, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_catalog_state(Catalog, DatabaseId, Expected, Deadline, undefined).

await_catalog_state(_Catalog, _DatabaseId, Expected, _Deadline,
                    {ok, #{state := Expected}}) -> ok;
await_catalog_state(Catalog, DatabaseId, Expected, Deadline, Last) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> ct:fail({catalog_state_timeout, Expected, Last});
        false ->
            timer:sleep(20),
            Result = erlite_catalog:database(
                       Catalog, DatabaseId, 15000, consistent),
            await_catalog_state(Catalog, DatabaseId, Expected, Deadline, Result)
    end.
