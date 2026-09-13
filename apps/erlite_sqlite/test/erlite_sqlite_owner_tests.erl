-module(erlite_sqlite_owner_tests).

-include_lib("eunit/include/eunit.hrl").

duplicate_open_returns_same_owner_test() ->
    with_supervised_database(
      fun(Root, DatabaseId, Owner) ->
              ?assertEqual({ok, Owner}, erlite_sqlite_databases:open(Root, DatabaseId)),
              ?assertEqual({ok, 0}, erlite_sqlite_owner:last_applied_index(Owner))
      end).

owner_exposes_runtime_compatibility_check_test() ->
    with_supervised_database(
      fun(_Root, _DatabaseId, Owner) ->
              {ok, Identity} = erlite_sqlite_owner:runtime_identity(Owner),
              ?assertEqual(ok, erlite_sqlite_owner:verify_runtime(Owner, Identity)),
              Different = Identity#{sqlite_version => <<"different">>},
              ?assertMatch({error, {incompatible_sqlite_runtime, _, _}},
                           erlite_sqlite_owner:verify_runtime(Owner, Different)),
              ?assertEqual({error, {invalid_sqlite_runtime_identity, invalid}},
                           erlite_sqlite_owner:verify_runtime(Owner, invalid)),
              ?assert(is_process_alive(Owner))
      end).

write_owner_uses_wal_with_full_synchronous_test() ->
    with_supervised_database(
      fun(_Root, _DatabaseId, Owner) ->
              ?assertEqual(
                 {ok, #{columns => [<<"journal_mode">>],
                         rows => [[<<"wal">>]]}},
                 erlite_sqlite_owner:query(
                   Owner, <<"PRAGMA journal_mode">>, [])),
              ?assertEqual(
                 {ok, #{columns => [<<"synchronous">>], rows => [[2]]}},
                 erlite_sqlite_owner:query(
                   Owner, <<"PRAGMA synchronous">>, []))
      end).

readonly_query_is_enforced_by_sqlite_and_restored_test() ->
    with_supervised_database(
      fun(_Root, _DatabaseId, Owner) ->
              {ok, _} = erlite_sqlite_owner:execute(
                          Owner, <<"CREATE TABLE guarded (value INTEGER)">>, []),
              ?assertMatch(
                 {error, _},
                 erlite_sqlite_owner:readonly_query(
                   Owner, <<"INSERT INTO guarded(value) VALUES (1)">>, [])),
              {ok, _} = erlite_sqlite_owner:execute(
                          Owner, <<"INSERT INTO guarded(value) VALUES (2)">>, []),
              ?assertMatch(
                 {ok, #{rows := [[2]]}},
                 erlite_sqlite_owner:readonly_query(
                   Owner, <<"SELECT value FROM guarded">>, []))
      end).

readonly_query_does_not_occupy_write_owner_test() ->
    with_supervised_database(
      fun(_Root, _DatabaseId, Owner) ->
              [Reader] = erlite_sqlite_owner:read_worker_pids(Owner),
              ?assertNotEqual(Owner, Reader),
              ok = sys:suspend(Reader),
              Parent = self(),
              {QueryPid, QueryMonitor} = spawn_monitor(
                                           fun() ->
                                                   Parent ! {
                                                     query_result,
                                                     erlite_sqlite_owner:readonly_query(
                                                       Owner, <<"SELECT 1">>, [])}
                                           end),
              ok = await_message_queue(Reader, 1, 100),
              ?assertMatch({ok, _}, erlite_sqlite_owner:execute(
                                      Owner,
                                      <<"CREATE TABLE owner_remains_free "
                                        "(value INTEGER)">>, [])),
              ok = sys:resume(Reader),
              receive
                  {query_result, Result} ->
                      ?assertMatch({ok, #{rows := [[1]]}}, Result)
              after 1000 ->
                  error(query_did_not_complete)
              end,
              receive
                  {'DOWN', QueryMonitor, process, QueryPid, normal} -> ok
              after 1000 ->
                  error(query_process_did_not_stop)
              end
      end).

owner_close_also_closes_read_worker_test() ->
    with_supervised_database(
      fun(_Root, _DatabaseId, Owner) ->
              [Reader] = erlite_sqlite_owner:read_worker_pids(Owner),
              ok = erlite_sqlite_owner:close(Owner),
              wait_until_dead(Owner),
              wait_until_dead(Reader)
      end).

configurable_read_pool_runs_queries_on_available_workers_test() ->
    with_read_pool_config(
      3, 64,
      fun() ->
              with_supervised_database(
                fun(_Root, _DatabaseId, Owner) ->
                        Readers = erlite_sqlite_owner:read_worker_pids(Owner),
                        ?assertEqual(3, length(Readers)),
                        lists:foreach(
                          fun(Reader) -> ok = sys:suspend(Reader) end, Readers),
                        Parent = self(),
                        Workers = [spawn_monitor(
                                     fun() ->
                                             Parent ! {
                                               Value,
                                               erlite_sqlite_owner:readonly_query(
                                                 Owner, <<"SELECT ?">>, [Value])}
                                     end) || Value <- lists:seq(1, 3)],
                        try
                            lists:foreach(
                              fun(Reader) ->
                                      ok = await_message_queue(Reader, 1, 100)
                              end, Readers),
                            #{workers := 3, busy := 3, queued := 0,
                              queue_limit := 64} =
                                erlite_sqlite_owner:read_pool_status(Owner),
                            ?assertMatch(
                               {ok, _},
                               erlite_sqlite_owner:execute(
                                 Owner,
                                 <<"CREATE TABLE pool_owner_free "
                                   "(value INTEGER)">>, []))
                        after
                            lists:foreach(
                              fun(Reader) -> ok = sys:resume(Reader) end, Readers)
                        end,
                        Results = [receive {Value, Result} -> {Value, Result}
                                   after 1000 -> error(query_did_not_complete)
                                   end || Value <- lists:seq(1, 3)],
                        ?assertEqual(
                           [{Value, [[Value]]} || Value <- lists:seq(1, 3)],
                           [{Value, Rows}
                            || {Value, {ok, #{rows := Rows}}} <- Results]),
                        lists:foreach(
                          fun({Pid, Monitor}) ->
                                  receive
                                      {'DOWN', Monitor, process, Pid, normal} -> ok
                                  after 1000 -> error(query_process_did_not_stop)
                                  end
                          end, Workers)
                end)
      end).

read_pool_rejects_when_bounded_queue_is_full_test() ->
    with_read_pool_config(
      1, 1,
      fun() ->
              with_supervised_database(
                fun(_Root, _DatabaseId, Owner) ->
                        [Reader] = erlite_sqlite_owner:read_worker_pids(Owner),
                        ok = sys:suspend(Reader),
                        Parent = self(),
                        First = spawn_monitor(
                                  fun() -> Parent ! {
                                             first,
                                             erlite_sqlite_owner:readonly_query(
                                               Owner, <<"SELECT 1">>, [])}
                                  end),
                        try
                            ok = await_message_queue(Reader, 1, 100),
                            Second = spawn_monitor(
                                       fun() -> Parent ! {
                                                  second,
                                                  erlite_sqlite_owner:readonly_query(
                                                    Owner, <<"SELECT 2">>, [])}
                                       end),
                            ok = await_pool_status(Owner, 1, 1, 100),
                            ?assertEqual(
                               {error, read_pool_overloaded},
                               erlite_sqlite_owner:readonly_query(
                                 Owner, <<"SELECT 3">>, [])),
                            put(second_worker, Second)
                        after
                            ok = sys:resume(Reader)
                        end,
                        ?assertMatch({ok, #{rows := [[1]]}},
                                     receive {first, FirstResult} -> FirstResult
                                     after 1000 -> error(first_query_timeout)
                                     end),
                        ?assertMatch({ok, #{rows := [[2]]}},
                                     receive {second, SecondResult} -> SecondResult
                                     after 1000 -> error(second_query_timeout)
                                     end),
                        await_worker_down(First),
                        await_worker_down(erase(second_worker))
                end)
      end).

owner_close_drains_accepted_read_work_test() ->
    with_read_pool_config(
      1, 1,
      fun() ->
              with_supervised_database(
                fun(_Root, _DatabaseId, Owner) ->
                        [Reader] = erlite_sqlite_owner:read_worker_pids(Owner),
                        ok = sys:suspend(Reader),
                        Parent = self(),
                        _ = spawn(fun() -> Parent ! {
                                                draining_first,
                                                erlite_sqlite_owner:readonly_query(
                                                  Owner, <<"SELECT 1">>, [])}
                                  end),
                        ok = await_message_queue(Reader, 1, 100),
                        _ = spawn(fun() -> Parent ! {
                                                draining_second,
                                                erlite_sqlite_owner:readonly_query(
                                                  Owner, <<"SELECT 2">>, [])}
                                  end),
                        ok = await_pool_status(Owner, 1, 1, 100),
                        Closer = spawn_monitor(
                                   fun() -> Parent ! {
                                              close_result,
                                              erlite_sqlite_owner:close(Owner)}
                                   end),
                        receive after 20 -> ok end,
                        ?assert(is_process_alive(Owner)),
                        ok = sys:resume(Reader),
                        ?assertMatch({ok, #{rows := [[1]]}},
                                     receive
                                         {draining_first, FirstResult} ->
                                             FirstResult
                                     after 1000 -> error(first_drain_timeout)
                                     end),
                        ?assertMatch({ok, #{rows := [[2]]}},
                                     receive
                                         {draining_second, SecondResult} ->
                                             SecondResult
                                     after 1000 -> error(second_drain_timeout)
                                     end),
                        receive {close_result, ok} -> ok
                        after 1000 -> error(close_did_not_complete)
                        end,
                        await_worker_down(Closer),
                        wait_until_dead(Owner)
                end)
      end).

invalid_read_pool_configuration_is_rejected_test() ->
    Root = temporary_root() ++ "-" ++
           integer_to_list(erlang:system_time(nanosecond)),
    DatabaseId = <<"invalid-read-pool">>,
    ok = erlite_sqlite_database:create(Root, DatabaseId),
    PreviousWorkers = application:get_env(erlite_sqlite, read_worker_count),
    PreviousQueue = application:get_env(erlite_sqlite, read_queue_limit),
    ok = application:set_env(erlite_sqlite, read_worker_count, 9),
    ok = application:set_env(erlite_sqlite, read_queue_limit, 64),
    PreviousTrap = process_flag(trap_exit, true),
    try
        ?assertEqual(
           {error, {shutdown, {invalid_read_pool_config, 9, 64}}},
           erlite_sqlite_owner:start_link(Root, DatabaseId))
    after
        _ = process_flag(trap_exit, PreviousTrap),
        restore_env(read_worker_count, PreviousWorkers),
        restore_env(read_queue_limit, PreviousQueue),
        ok = erlite_sqlite_database:delete(Root, DatabaseId),
        _ = file:del_dir(Root)
    end.

readonly_query_reset_failure_is_fatal_test() ->
    Connection = {erlite_sqlite_query_only_failure_adapter, connection},
    ?assertEqual(
       {fatal, {query_only_reset_failed, simulated_reset_failure}},
       erlite_sqlite_owner:readonly_query_connection(
         Connection, <<"SELECT 1">>, [])).

concurrent_duplicate_apply_is_serialized_test() ->
    with_supervised_database(
      fun(_Root, _DatabaseId, Owner) ->
              {ok, _} = erlite_sqlite_owner:execute(
                          Owner,
                          <<"CREATE TABLE applied_values (value TEXT)">>,
                          []),
              Statement = {execute,
                           <<"INSERT INTO applied_values(value) VALUES (?)">>,
                           [<<"once">>]},
              Parent = self(),
              Workers = [spawn_monitor(
                           fun() ->
                                   Parent ! {self(),
                                             erlite_sqlite_owner:apply_committed(
                                               Owner, 0, 1, <<"tx-1">>,
                                               crypto:hash(sha256, <<"command">>),
                                               [Statement])}
                           end) || _ <- lists:seq(1, 20)],
              Results = [receive {Pid, Result} -> Result end || {Pid, _Ref} <- Workers],
              ?assertEqual(1, length([applied || {ok, applied} <- Results])),
              ?assertEqual(19,
                           length([already_applied || {ok, already_applied} <- Results])),
              ?assertEqual({ok, 1}, erlite_sqlite_owner:last_applied_index(Owner)),
              ?assertMatch({ok, #{rows := [[1]]}},
                           erlite_sqlite_owner:query(
                             Owner, <<"SELECT count(*) FROM applied_values">>, []))
      end).

owner_exit_allows_a_fresh_owner_test() ->
    with_supervised_database(
      fun(Root, DatabaseId, Owner) ->
              ok = erlite_sqlite_owner:close(Owner),
              wait_until_dead(Owner),
              {ok, NewOwner} = await_reopen(Root, DatabaseId, 20),
              ?assertNotEqual(Owner, NewOwner),
              ?assertEqual({ok, 0}, erlite_sqlite_owner:last_applied_index(NewOwner))
      end).

registry_close_is_idempotent_and_allows_reopen_test() ->
    with_supervised_database(
      fun(Root, DatabaseId, Owner) ->
              ?assertEqual(ok, erlite_sqlite_databases:close(Root, DatabaseId)),
              wait_until_dead(Owner),
              ?assertEqual(ok, erlite_sqlite_databases:close(Root, DatabaseId)),
              {ok, NewOwner} = erlite_sqlite_databases:open(Root, DatabaseId),
              ?assertEqual(
                 {ok, #{columns => [<<"journal_mode">>],
                         rows => [[<<"wal">>]]}},
                 erlite_sqlite_owner:query(
                   NewOwner, <<"PRAGMA journal_mode">>, [])),
              ?assertEqual(
                 {ok, #{columns => [<<"synchronous">>], rows => [[2]]}},
                 erlite_sqlite_owner:query(
                   NewOwner, <<"PRAGMA synchronous">>, [])),
              ?assertNotEqual(Owner, NewOwner)
      end).

registry_delete_closes_owner_before_removing_files_test() ->
    Root = temporary_root(),
    DatabaseId = <<"delete-open-database">>,
    {ok, Sup} = erlite_sqlite_sup:start_link(),
    unlink(Sup),
    try
        ok = erlite_sqlite_databases:create(Root, DatabaseId),
        {ok, Owner} = erlite_sqlite_databases:open(Root, DatabaseId),
        ?assertEqual(ok, erlite_sqlite_databases:delete(Root, DatabaseId)),
        wait_until_dead(Owner),
        ?assertEqual({error, database_not_found},
                     erlite_sqlite_databases:open(Root, DatabaseId)),
        ?assertEqual(ok, erlite_sqlite_databases:delete(Root, DatabaseId))
    after
        exit(Sup, shutdown),
        wait_until_dead(Sup),
        _ = erlite_sqlite_database:delete(Root, DatabaseId),
        _ = file:del_dir(Root)
    end.

with_supervised_database(Test) ->
    Root = temporary_root(),
    DatabaseId = <<"supervised-database">>,
    ok = erlite_sqlite_database:create(Root, DatabaseId),
    {ok, Sup} = erlite_sqlite_sup:start_link(),
    unlink(Sup),
    try
        {ok, Owner} = erlite_sqlite_databases:open(Root, DatabaseId),
        Test(Root, DatabaseId, Owner)
    after
        exit(Sup, shutdown),
        wait_until_dead(Sup),
        ok = erlite_sqlite_database:delete(Root, DatabaseId),
        _ = file:del_dir(Root)
    end.

await_reopen(_Root, _DatabaseId, 0) ->
    {error, owner_registry_timeout};
await_reopen(Root, DatabaseId, Attempts) ->
    case erlite_sqlite_databases:open(Root, DatabaseId) of
        {ok, Pid} -> {ok, Pid};
        {error, _Reason} ->
            receive after 5 -> ok end,
            await_reopen(Root, DatabaseId, Attempts - 1)
    end.

wait_until_dead(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 ->
        error({process_did_not_stop, Pid})
    end.

await_message_queue(_Pid, _Minimum, 0) ->
    {error, message_not_queued};
await_message_queue(Pid, Minimum, Attempts) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, Length} when Length >= Minimum -> ok;
        _ ->
            receive after 5 -> ok end,
            await_message_queue(Pid, Minimum, Attempts - 1)
    end.

await_pool_status(_Owner, _Busy, _Queued, 0) ->
    {error, pool_status_timeout};
await_pool_status(Owner, Busy, Queued, Attempts) ->
    case erlite_sqlite_owner:read_pool_status(Owner) of
        #{busy := Busy, queued := Queued} -> ok;
        _ ->
            receive after 5 -> ok end,
            await_pool_status(Owner, Busy, Queued, Attempts - 1)
    end.

await_worker_down({Pid, Monitor}) ->
    receive
        {'DOWN', Monitor, process, Pid, normal} -> ok
    after 1000 ->
        error(query_process_did_not_stop)
    end.

with_read_pool_config(Workers, QueueLimit, Test) ->
    PreviousWorkers = application:get_env(erlite_sqlite, read_worker_count),
    PreviousQueue = application:get_env(erlite_sqlite, read_queue_limit),
    ok = application:set_env(erlite_sqlite, read_worker_count, Workers),
    ok = application:set_env(erlite_sqlite, read_queue_limit, QueueLimit),
    try Test()
    after
        restore_env(read_worker_count, PreviousWorkers),
        restore_env(read_queue_limit, PreviousQueue)
    end.

restore_env(Key, {ok, Value}) -> application:set_env(erlite_sqlite, Key, Value);
restore_env(Key, undefined) -> application:unset_env(erlite_sqlite, Key).

temporary_root() ->
    Name = io_lib:format("erlite-owner-~B",
                         [erlang:unique_integer([positive, monotonic])]),
    filename:join(temp_directory(), lists:flatten(Name)).

temp_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.
