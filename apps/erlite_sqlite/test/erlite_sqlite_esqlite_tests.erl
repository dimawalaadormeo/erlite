-module(erlite_sqlite_esqlite_tests).

-include_lib("eunit/include/eunit.hrl").

file_backed_crud_test() ->
    with_database(
      fun(Connection) ->
              {ok, _} = erlite_sqlite:execute(Connection,
                                              <<"CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, note TEXT)">>,
                                              []),
              {ok, Insert} = erlite_sqlite:execute(Connection,
                                                   <<"INSERT INTO items(name, note) VALUES (?, ?)">>,
                                                   [<<"apple">>, null]),
              ?assertEqual(1, maps:get(changes, Insert)),
              ?assert(maps:get(last_insert_rowid, Insert) > 0),
              ?assertEqual({ok, #{columns => [<<"name">>, <<"note">>],
                                  rows => [[<<"apple">>, null]]}},
                           erlite_sqlite:query(Connection,
                                               <<"SELECT name, note FROM items WHERE name = ?">>,
                                               [<<"apple">>]))
      end).

failed_transaction_rolls_back_test() ->
    with_database(
      fun(Connection) ->
              {ok, _} = erlite_sqlite:execute(Connection,
                                              <<"CREATE TABLE items (name TEXT NOT NULL UNIQUE)">>,
                                              []),
              Statements = [{execute, <<"INSERT INTO items(name) VALUES (?)">>, [<<"same">>]},
                            {execute, <<"INSERT INTO items(name) VALUES (?)">>, [<<"same">>]}],
              ?assertMatch({error, _}, erlite_sqlite:transaction(Connection, Statements)),
              ?assertEqual({ok, #{columns => [<<"count">>], rows => [[0]]}},
                           erlite_sqlite:query(Connection,
                                               <<"SELECT count(*) AS count FROM items">>,
                                               []))
      end).

successful_transaction_returns_ordered_results_test() ->
    with_database(
      fun(Connection) ->
              {ok, _} = erlite_sqlite:execute(Connection,
                                              <<"CREATE TABLE items (name TEXT NOT NULL)">>,
                                              []),
              Statements = [{execute, <<"INSERT INTO items(name) VALUES (?)">>, [<<"first">>]},
                            {query, <<"SELECT name FROM items ORDER BY rowid">>, []}],
              ?assertMatch({ok, [#{changes := 1},
                                  #{columns := [<<"name">>], rows := [[<<"first">>]]}]},
                           erlite_sqlite:transaction(Connection, Statements))
      end).

unsupported_open_options_test() ->
    ?assertEqual({error, {unsupported_open_options, #{mode => read_only}}},
                 erlite_sqlite_esqlite:open("unused.sqlite", #{mode => read_only})).

with_database(Test) ->
    Path = temporary_database_path(),
    {ok, Connection} = erlite_sqlite:open(Path),
    try
        Test(Connection)
    after
        ok = erlite_sqlite:close(Connection),
        ok = delete_if_present(Path),
        ok = delete_if_present(Path ++ "-shm"),
        ok = delete_if_present(Path ++ "-wal")
    end.

temporary_database_path() ->
    Name = io_lib:format("erlite-esqlite-~B.sqlite",
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

