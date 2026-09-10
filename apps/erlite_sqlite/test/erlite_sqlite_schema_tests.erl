-module(erlite_sqlite_schema_tests).

-include_lib("eunit/include/eunit.hrl").

initialization_is_idempotent_and_durable_test() ->
    with_database(
      fun(Path, Connection) ->
              ?assertEqual(ok, erlite_sqlite_schema:initialize(Connection)),
              ?assertEqual(ok, erlite_sqlite_schema:initialize(Connection)),
              ?assertEqual({ok, 0}, erlite_sqlite_schema:last_applied_index(Connection)),
              ok = erlite_sqlite:close(Connection),
              {ok, Reopened} = erlite_sqlite:open(Path),
              ?assertEqual({ok, 0}, erlite_sqlite_schema:last_applied_index(Reopened)),
              Reopened
      end).

apply_and_duplicate_delivery_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              {ok, _} = erlite_sqlite:execute(Connection,
                                              <<"CREATE TABLE values_table (value TEXT)">>,
                                              []),
              Statements = [{execute,
                             <<"INSERT INTO values_table(value) VALUES (?)">>,
                             [<<"once">>]}],
              ?assertEqual({ok, applied},
                           apply(Connection, 0, 1, <<"tx-1">>, <<"one">>, Statements)),
              ?assertEqual({ok, already_applied},
                           apply(Connection, 0, 1, <<"tx-1">>, <<"one">>, Statements)),
              ?assertEqual({ok, 1}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertMatch({ok, #{rows := [[1]]}},
                           erlite_sqlite:query(Connection,
                                               <<"SELECT count(*) FROM values_table">>,
                                               [])),
              Connection
      end).

deterministic_failed_apply_advances_index_without_partial_work_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              {ok, _} = erlite_sqlite:execute(
                          Connection,
                          <<"CREATE TABLE values_table (value TEXT UNIQUE)">>,
                          []),
              Statements = [
                  {execute, <<"INSERT INTO values_table(value) VALUES (?)">>, [<<"same">>]},
                  {execute, <<"INSERT INTO values_table(value) VALUES (?)">>, [<<"same">>]}
              ],
              ?assertEqual({ok, transaction_failed},
                           apply(Connection, 0, 1, <<"tx-1">>, <<"bad">>, Statements)),
              ?assertEqual({ok, 1}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertMatch({ok, #{rows := [[0]]}},
                           erlite_sqlite:query(Connection,
                                               <<"SELECT count(*) FROM values_table">>,
                                               [])),
              Connection
      end).

invalid_transition_and_query_statement_are_rejected_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              Query = {query, <<"SELECT 1">>, []},
              ?assertEqual({error, {invalid_replicated_statement, Query}},
                           apply(Connection, 0, 1, <<"tx-1">>, <<"query">>, [Query])),
              ?assertEqual({error, {invalid_raft_index_transition, 1, 1}},
                           apply(Connection, 1, 1, <<"tx-1">>, <<"same">>, [])),
              Connection
      end).

known_raft_index_gap_can_be_advanced_atomically_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              {ok, _} = erlite_sqlite:execute(
                          Connection, <<"CREATE TABLE values_table (value TEXT)">>, []),
              Statements = [{execute,
                             <<"INSERT INTO values_table(value) VALUES (?)">>,
                             [<<"at-five">>]}],
              ?assertEqual({ok, applied},
                           erlite_sqlite_schema:apply_committed(
                             Connection, 0, 5, <<"tx-5">>, hash(<<"five">>),
                             Statements)),
              ?assertEqual({ok, 5}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertEqual({ok, already_applied},
                           erlite_sqlite_schema:apply_committed(
                             Connection, 0, 5, <<"tx-5">>, hash(<<"five">>),
                             Statements)),
              ?assertEqual({error, {raft_index_mismatch, 2, 5, 8}},
                           erlite_sqlite_schema:apply_committed(
                             Connection, 2, 8, <<"tx-8">>, hash(<<"eight">>),
                             Statements)),
              Connection
      end).

logical_transaction_retry_is_deduplicated_and_conflicts_fail_closed_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              {ok, _} = erlite_sqlite:execute(
                          Connection, <<"CREATE TABLE values_table (value TEXT)">>, []),
              Statement = {execute,
                           <<"INSERT INTO values_table(value) VALUES (?)">>,
                           [<<"once">>]},
              ?assertEqual({ok, applied},
                           apply(Connection, 0, 2, <<"logical-tx">>,
                                 <<"command-a">>, [Statement])),
              ?assertEqual({ok, already_applied},
                           apply(Connection, 2, 7, <<"logical-tx">>,
                                 <<"command-a">>, [Statement])),
              ?assertEqual({ok, transaction_id_conflict},
                           apply(Connection, 7, 9, <<"logical-tx">>,
                                 <<"command-b">>, [Statement])),
              ?assertEqual({ok, 9}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertMatch({ok, #{rows := [[1]]}},
                           erlite_sqlite:query(
                             Connection, <<"SELECT count(*) FROM values_table">>, [])),
              Connection
      end).

reset_raft_history_preserves_user_data_and_clears_source_ledger_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              {ok, _} = erlite_sqlite:execute(
                          Connection,
                          <<"CREATE TABLE restored (value TEXT)">>, []),
              {ok, applied} = apply(
                                Connection, 0, 7, <<"old-tx">>, <<"old">>,
                                [{execute,
                                  <<"INSERT INTO restored VALUES (?)">>,
                                  [<<"kept">>]}]),
              ok = erlite_sqlite_schema:reset_raft_history(Connection),
              {ok, 0} = erlite_sqlite_schema:last_applied_index(Connection),
              new = erlite_sqlite_schema:transaction_status(
                      Connection, <<"old-tx">>, hash(<<"old">>)),
              {ok, #{rows := [[<<"kept">>]]}} = erlite_sqlite:query(
                                                    Connection,
                                                    <<"SELECT value FROM restored">>,
                                                    []),
              Connection
      end).

migration_is_atomic_versioned_and_idempotent_test() ->
    with_database(
      fun(_Path, Connection) ->
          ok = erlite_sqlite_schema:initialize(Connection),
          Hash = hash(<<"migration-one">>),
          Statements = [{execute,
                         <<"CREATE TABLE migrated (id INTEGER PRIMARY KEY)">>,
                         []}],
          ?assertEqual({ok, applied}, erlite_sqlite_schema:apply_migration(
                         Connection, 0, 1, <<"app">>, <<"one">>, Hash,
                         0, 1, Statements)),
          ?assertEqual({ok, 1}, erlite_sqlite_schema:schema_version(Connection)),
          ?assertEqual({ok, already_applied},
                       erlite_sqlite_schema:apply_migration(
                         Connection, 1, 2, <<"app">>, <<"one">>, Hash,
                         0, 1, Statements)),
          ?assertEqual({error, {schema_version_mismatch, 0, 1}},
                       erlite_sqlite_schema:apply_committed(
                         Connection, 2, 3, <<"old-client">>, hash(<<"tx">>),
                         0, [{execute, <<"INSERT INTO migrated VALUES (?)">>,
                              [1]}])),
          ?assertMatch({ok, #{rows := [[<<"app">>, <<"one">>, 0, 1, 1]]}},
                       erlite_sqlite_schema:migration_history(Connection)),
          Connection
      end).

unsafe_migration_is_rejected_before_sqlite_state_changes_test() ->
    with_database(
      fun(_Path, Connection) ->
          ok = erlite_sqlite_schema:initialize(Connection),
          Unsafe = [{execute,
                     <<"CREATE TABLE poisoned (x TEXT DEFAULT(RANDOM()))">>,
                     []}],
          ?assertEqual({error, unsafe_migration_sql},
                       erlite_sqlite_schema:apply_migration(
                         Connection, 0, 1, <<"app">>, <<"poison">>,
                         hash(<<"poison">>), 0, 1, Unsafe)),
          ?assertEqual({ok, 0}, erlite_sqlite_schema:last_applied_index(Connection)),
          ?assertEqual({ok, 0}, erlite_sqlite_schema:schema_version(Connection)),
          ?assertMatch({ok, #{rows := []}},
                       erlite_sqlite_schema:migration_history(Connection)),
          ?assertMatch({ok, #{rows := []}},
                       erlite_sqlite:query(
                         Connection,
                         <<"SELECT name FROM sqlite_schema WHERE name='poisoned'">>,
                         [])),
          Connection
      end).

disk_full_does_not_advance_applied_index_test() ->
    Path = temporary_database_path(),
    ok = erlite_sqlite_disk_full_adapter:fail_transactions(false),
    {ok, Connection} = erlite_sqlite:open(
                         Path, #{adapter => erlite_sqlite_disk_full_adapter}),
    try
        ok = erlite_sqlite_schema:initialize(Connection),
        {ok, _} = erlite_sqlite:execute(
                    Connection, <<"CREATE TABLE disk_test (value TEXT)">>, []),
        ok = erlite_sqlite_disk_full_adapter:fail_transactions(true),
        ?assertEqual({error, enospc},
                     apply(Connection, 0, 1, <<"disk-full">>, <<"disk-full">>,
                           [{execute,
                             <<"INSERT INTO disk_test(value) VALUES (?)">>,
                             [<<"not-committed">>]}])),
        ?assertEqual({ok, 0}, erlite_sqlite_schema:last_applied_index(Connection)),
        ?assertMatch({ok, #{rows := [[0]]}},
                     erlite_sqlite:query(
                       Connection, <<"SELECT count(*) FROM disk_test">>, []))
    after
        ok = erlite_sqlite_disk_full_adapter:fail_transactions(false),
        ok = erlite_sqlite:close(Connection),
        ok = delete_if_present(Path),
        ok = delete_if_present(Path ++ "-shm"),
        ok = delete_if_present(Path ++ "-wal")
    end.

deterministic_migration_failure_is_durably_skipped_test() ->
    with_database(
      fun(_Path, Connection) ->
          ok = erlite_sqlite_schema:initialize(Connection),
          {ok, _} = erlite_sqlite:execute(
                      Connection, <<"CREATE TABLE collision (id INTEGER)">>, []),
          ?assertEqual(
             {ok, migration_failed},
             erlite_sqlite_schema:apply_migration(
               Connection, 0, 1, <<"app">>, <<"collision">>,
               hash(<<"collision">>), 0, 1,
               [{execute, <<"CREATE TABLE collision (id INTEGER)">>, []}])),
          ?assertEqual({ok, 1},
                       erlite_sqlite_schema:last_applied_index(Connection)),
          ?assertEqual({ok, 0}, erlite_sqlite_schema:schema_version(Connection)),
          ?assertMatch({ok, #{rows := []}},
                       erlite_sqlite_schema:migration_history(Connection)),
          Connection
      end).

deterministic_write_failure_does_not_poison_later_entries_test() ->
    with_database(
      fun(_Path, Connection) ->
          ok = erlite_sqlite_schema:initialize(Connection),
          {ok, _} = erlite_sqlite:execute(
                      Connection,
                      <<"CREATE TABLE unique_values (value TEXT UNIQUE)">>, []),
          {ok, _} = erlite_sqlite:execute(
                      Connection,
                      <<"INSERT INTO unique_values(value) VALUES (?)">>,
                      [<<"same">>]),
          RejectedHash = hash(<<"rejected">>),
          ?assertEqual(
             {ok, transaction_failed},
             erlite_sqlite_schema:apply_committed(
               Connection, 0, 1, <<"rejected">>, RejectedHash, 0,
               [{execute,
                 <<"INSERT INTO unique_values(value) VALUES (?)">>,
                 [<<"same">>]}])),
          ?assertEqual(rejected, erlite_sqlite_schema:transaction_status(
                                   Connection, <<"rejected">>, RejectedHash)),
          ?assertEqual({ok, 1},
                       erlite_sqlite_schema:last_applied_index(Connection)),
          ?assertEqual(
             {ok, applied},
             apply(Connection, 1, 2, <<"later">>, <<"later">>,
                   [{execute,
                     <<"INSERT INTO unique_values(value) VALUES (?)">>,
                     [<<"later">>]}])),
          ?assertMatch({ok, #{rows := [[2]]}},
                       erlite_sqlite:query(
                         Connection, <<"SELECT count(*) FROM unique_values">>, [])),
          Connection
      end).

apply(Connection, Expected, Index, TransactionId, Command, Statements) ->
    erlite_sqlite_schema:apply_committed(
      Connection, Expected, Index, TransactionId, hash(Command), Statements).

hash(Value) -> crypto:hash(sha256, Value).

with_database(Test) ->
    Path = temporary_database_path(),
    {ok, Connection} = erlite_sqlite:open(Path),
    try
        FinalConnection = Test(Path, Connection),
        ok = erlite_sqlite:close(FinalConnection)
    after
        ok = delete_if_present(Path),
        ok = delete_if_present(Path ++ "-shm"),
        ok = delete_if_present(Path ++ "-wal")
    end.

temporary_database_path() ->
    Name = io_lib:format("erlite-schema-~B.sqlite",
                         [erlang:unique_integer([positive, monotonic])]),
    filename:join(temp_directory(), lists:flatten(Name)).

temp_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.

delete_if_present(Path) ->
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok
    end.
