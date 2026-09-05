-module(erlite_sqlite_tests).

-include_lib("eunit/include/eunit.hrl").

explicit_adapter_dispatches_operations_test() ->
    {ok, Connection} = erlite_sqlite:open("database.sqlite",
                                          #{adapter => erlite_sqlite_test_adapter,
                                            mode => read_write}),
    ?assertEqual({ok, #{changes => 1, last_insert_rowid => 7}},
                 erlite_sqlite:execute(Connection, <<"INSERT INTO t VALUES (?)">>, [42])),
    ?assertEqual({ok, #{columns => [<<"value">>], rows => [[42]]}},
                 erlite_sqlite:query(Connection, <<"SELECT ?">>, [42])),
    Statements = [{execute, <<"INSERT INTO t VALUES (?)">>, [42]},
                  {query, <<"SELECT ?">>, [42]}],
    ?assertMatch({ok, [#{changes := 1}, #{rows := [[42]]}]},
                 erlite_sqlite:transaction(Connection, Statements)),
    ?assertEqual(ok, erlite_sqlite:close(Connection)).

adapter_option_is_not_forwarded_test() ->
    {ok, {erlite_sqlite_test_adapter, {_Path, BackendOptions}}} =
        erlite_sqlite:open("database.sqlite",
                           #{adapter => erlite_sqlite_test_adapter,
                             mode => read_only}),
    ?assertEqual(#{mode => read_only}, BackendOptions).

undefined_adapter_is_an_error_test() ->
    ?assertEqual({error, {invalid_adapter, undefined}},
                 erlite_sqlite:open("database.sqlite", #{adapter => undefined})).

invalid_adapter_is_an_error_test() ->
    ?assertEqual({error, {invalid_adapter, not_an_erlite_adapter}},
                 erlite_sqlite:open("database.sqlite",
                                    #{adapter => not_an_erlite_adapter})).

