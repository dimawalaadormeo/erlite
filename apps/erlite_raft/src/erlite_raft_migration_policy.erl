-module(erlite_raft_migration_policy).

-export([validate/2]).

%% Migration DDL is deliberately narrower than SQLite. In particular it bans
%% data-dependent expressions and every Erlite-owned object.
validate(Sql, Params) when is_binary(Sql), is_list(Params) ->
    case placeholder_count(Sql) =:= length(Params) of
        false -> {error, unsafe_migration_sql};
        true -> erlite_sqlite_schema_policy:validate_migration_statement(Sql)
    end.

placeholder_count(Sql) ->
    length([C || <<C>> <= Sql, C =:= $?]).
