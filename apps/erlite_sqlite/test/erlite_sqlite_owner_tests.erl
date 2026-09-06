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

temporary_root() ->
    Name = io_lib:format("erlite-owner-~B",
                         [erlang:unique_integer([positive, monotonic])]),
    filename:join(temp_directory(), lists:flatten(Name)).

temp_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.
