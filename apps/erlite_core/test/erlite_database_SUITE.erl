-module(erlite_database_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         multiple_database_lifecycle_and_isolation/1]).

all() -> [multiple_database_lifecycle_and_isolation].

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
    [{root, Root}, {supervisor, Sup} | Config].

end_per_suite(Config) ->
    Sup = proplists:get_value(supervisor, Config),
    ok = gen_server:stop(Sup, normal, 5000),
    _ = application:stop(erlite_raft),
    _ = application:stop(ra),
    cleanup(proplists:get_value(root, Config)),
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
