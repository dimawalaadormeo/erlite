-module(erlite_sqlite_disk_full_adapter).
-behaviour(erlite_sqlite_adapter).

-export([open/2, close/1, execute/3, query/3, transaction/2,
         fail_transactions/1]).

-define(KEY, {?MODULE, fail_transactions}).

fail_transactions(Value) when is_boolean(Value) ->
    persistent_term:put(?KEY, Value),
    ok.

open(Path, Options) -> erlite_sqlite_esqlite:open(Path, Options).
close(Connection) -> erlite_sqlite_esqlite:close(Connection).
execute(Connection, Sql, Params) ->
    erlite_sqlite_esqlite:execute(Connection, Sql, Params).
query(Connection, Sql, Params) ->
    erlite_sqlite_esqlite:query(Connection, Sql, Params).
transaction(Connection, Statements) ->
    case persistent_term:get(?KEY, false) of
        true -> {error, enospc};
        false -> erlite_sqlite_esqlite:transaction(Connection, Statements)
    end.
