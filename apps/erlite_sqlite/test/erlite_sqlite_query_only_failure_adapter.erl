-module(erlite_sqlite_query_only_failure_adapter).
-behaviour(erlite_sqlite_adapter).

-export([open/2, close/1, execute/3, query/3, transaction/2]).

open(_Path, _Options) -> {ok, connection}.
close(_Connection) -> ok.

execute(_Connection, <<"PRAGMA query_only = ON">>, []) ->
    {ok, #{changes => 0, last_insert_rowid => undefined}};
execute(_Connection, <<"PRAGMA query_only = OFF">>, []) ->
    {error, simulated_reset_failure};
execute(_Connection, _Sql, _Params) ->
    {ok, #{changes => 0, last_insert_rowid => undefined}}.

query(_Connection, _Sql, _Params) ->
    {ok, #{columns => [<<"value">>], rows => [[1]]}}.

transaction(_Connection, _Statements) -> {ok, []}.
