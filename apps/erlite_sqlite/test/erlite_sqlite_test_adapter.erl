-module(erlite_sqlite_test_adapter).
-behaviour(erlite_sqlite_adapter).

-export([open/2, close/1, execute/3, query/3, transaction/2]).

open(Path, Options) ->
    {ok, {Path, Options}}.

close(_Connection) ->
    ok.

execute(_Connection, _Sql, _Params) ->
    {ok, #{changes => 1, last_insert_rowid => 7}}.

query(_Connection, _Sql, _Params) ->
    {ok, #{columns => [<<"value">>], rows => [[42]]}}.

transaction(_Connection, Statements) ->
    Results = [result_for(Statement) || Statement <- Statements],
    {ok, Results}.

result_for({execute, _Sql, _Params}) ->
    #{changes => 1, last_insert_rowid => undefined};
result_for({query, _Sql, _Params}) ->
    #{columns => [<<"value">>], rows => [[42]]}.

