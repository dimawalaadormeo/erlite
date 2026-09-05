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
                           erlite_sqlite_schema:apply_committed(Connection, 1, Statements)),
              ?assertEqual({ok, already_applied},
                           erlite_sqlite_schema:apply_committed(Connection, 1, Statements)),
              ?assertEqual({ok, 1}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertMatch({ok, #{rows := [[1]]}},
                           erlite_sqlite:query(Connection,
                                               <<"SELECT count(*) FROM values_table">>,
                                               [])),
              Connection
      end).

failed_apply_does_not_advance_index_or_commit_partial_work_test() ->
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
              ?assertMatch({error, _},
                           erlite_sqlite_schema:apply_committed(Connection, 1, Statements)),
              ?assertEqual({ok, 0}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertMatch({ok, #{rows := [[0]]}},
                           erlite_sqlite:query(Connection,
                                               <<"SELECT count(*) FROM values_table">>,
                                               [])),
              Connection
      end).

index_gap_and_query_statement_are_rejected_test() ->
    with_database(
      fun(_Path, Connection) ->
              ok = erlite_sqlite_schema:initialize(Connection),
              ?assertEqual({error, {raft_index_gap, 0, 2}},
                           erlite_sqlite_schema:apply_committed(Connection, 2, [])),
              Query = {query, <<"SELECT 1">>, []},
              ?assertEqual({error, {invalid_replicated_statement, Query}},
                           erlite_sqlite_schema:apply_committed(Connection, 1, [Query])),
              ?assertEqual({error, {invalid_raft_index, 0}},
                           erlite_sqlite_schema:apply_committed(Connection, 0, [])),
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
                             Connection, 0, 5, Statements)),
              ?assertEqual({ok, 5}, erlite_sqlite_schema:last_applied_index(Connection)),
              ?assertEqual({ok, already_applied},
                           erlite_sqlite_schema:apply_committed(
                             Connection, 0, 5, Statements)),
              ?assertEqual({error, {raft_index_mismatch, 2, 5, 8}},
                           erlite_sqlite_schema:apply_committed(
                             Connection, 2, 8, Statements)),
              Connection
      end).

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
