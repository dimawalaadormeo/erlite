-module(erlite_raft_sql_policy).

-export([validate/2]).

-define(IDENTIFIER, "[A-Z_][A-Z0-9_]*").
-define(PREDICATE, ?IDENTIFIER "\\s*=\\s*\\?").

-spec validate(binary(), erlite_sqlite_adapter:params()) ->
    ok | {error, term()}.
validate(Sql, Params) when is_binary(Sql), is_list(Params) ->
    case targets_internal_table(Sql) of
        true -> {error, {reserved_internal_table, Sql}};
        false ->
            case matches_supported_statement(Sql) of
                true -> validate_parameter_count(Sql, Params);
                false -> {error, {unsupported_replicated_sql, Sql}}
            end
    end.

targets_internal_table(Sql) ->
    matches(Sql,
            "^\\s*(?:INSERT\\s+INTO|UPDATE|DELETE\\s+FROM)\\s+__ERLITE_").

matches_supported_statement(Sql) ->
    matches(Sql, insert_pattern()) orelse
        matches(Sql, update_pattern()) orelse
        matches(Sql, delete_pattern()).

matches(Sql, Pattern) ->
    try re:run(Sql, Pattern, [caseless, unicode, {capture, none}]) of
        match -> true;
        nomatch -> false
    catch
        error:badarg -> false
    end.

insert_pattern() ->
    "^\\s*INSERT\\s+INTO\\s+" ?IDENTIFIER
    "\\s*\\(\\s*" ?IDENTIFIER
    "(?:\\s*,\\s*" ?IDENTIFIER ")*\\s*\\)"
    "\\s*VALUES\\s*\\(\\s*\\?(?:\\s*,\\s*\\?)*\\s*\\)\\s*$".

update_pattern() ->
    "^\\s*UPDATE\\s+" ?IDENTIFIER
    "\\s+SET\\s+" ?PREDICATE
    "(?:\\s*,\\s*" ?PREDICATE ")*"
    "(?:\\s+WHERE\\s+" ?PREDICATE
    "(?:\\s+AND\\s+" ?PREDICATE ")*)?\\s*$".

delete_pattern() ->
    "^\\s*DELETE\\s+FROM\\s+" ?IDENTIFIER
    "\\s+WHERE\\s+" ?PREDICATE
    "(?:\\s+AND\\s+" ?PREDICATE ")*\\s*$".

validate_parameter_count(Sql, Params) ->
    PlaceholderCount = length(binary:matches(Sql, <<"?">>)),
    ParameterCount = length(Params),
    case PlaceholderCount =:= ParameterCount of
        true -> ok;
        false ->
            {error, {parameter_count_mismatch, PlaceholderCount, ParameterCount}}
    end.
