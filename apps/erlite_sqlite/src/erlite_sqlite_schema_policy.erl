-module(erlite_sqlite_schema_policy).

-export([validate/1, validate_migration_statement/1]).

-spec validate_migration_statement(binary()) -> ok | {error, term()}.
validate_migration_statement(Sql) when is_binary(Sql), byte_size(Sql) > 0 ->
    case valid_utf8(Sql) of
        false -> {error, invalid_migration_sql_encoding};
        true ->
            case has_unsafe_migration_token(Sql) of
                true -> {error, unsafe_migration_sql};
                false -> allowed_migration_statement(Sql)
            end
    end;
validate_migration_statement(_) ->
    {error, invalid_migration_sql}.

allowed_migration_statement(Sql) ->
    Pattern = <<"^\\s*(?:CREATE\\s+(?:UNIQUE\\s+)?INDEX|CREATE\\s+TABLE|"
                "ALTER\\s+TABLE|DROP\\s+INDEX|DROP\\s+TABLE)\\b">>,
    case re:run(Sql, Pattern, [caseless, unicode, {capture, none}]) of
        match -> ok;
        nomatch -> {error, unsupported_migration_sql};
        {error, _} -> {error, invalid_migration_sql_encoding}
    end.

has_unsafe_migration_token(Sql) ->
    %% Word boundaries make punctuation and arbitrary whitespace irrelevant.
    %% AS and CHECK are conservative bans: they close CTAS, generated columns,
    %% expression constraints, and other data-dependent schema forms.
    Patterns = [<<";|--|/\\*|\\b__erlite_">>,
                <<"\\b(?:TRIGGER|VIEW|VIRTUAL|DEFAULT|COLLATE|GENERATED|AS|CHECK)\\b">>,
                <<"\\b(?:CURRENT_DATE|CURRENT_TIME|CURRENT_TIMESTAMP)\\b">>,
                <<"\\b(?:RANDOM|RANDOMBLOB|STRFTIME|DATE|TIME|DATETIME|JULIANDAY)\\s*\\(">>],
    lists:any(fun(Pattern) ->
                      re:run(Sql, Pattern,
                             [caseless, unicode, {capture, none}]) =:= match
              end, Patterns).

valid_utf8(Sql) ->
    case unicode:characters_to_list(Sql, utf8) of
        List when is_list(List) -> true;
        _ -> false
    end.

-spec validate(erlite_sqlite:connection()) -> ok | {error, term()}.
validate(Connection) ->
    Sql = <<"SELECT type, name, sql FROM sqlite_schema "
            "WHERE name NOT LIKE 'sqlite_%' "
            "AND name NOT LIKE '__erlite_%' "
            "ORDER BY type, name">>,
    case erlite_sqlite:query(Connection, Sql, []) of
        {ok, #{rows := Rows}} -> validate_objects(Rows);
        {error, _Reason} = Error -> Error
    end.

validate_objects([]) ->
    ok;
validate_objects([[<<"table">>, Name, Definition] | Rest])
  when is_binary(Name), is_binary(Definition) ->
    case validate_table_definition(Definition) of
        ok -> validate_objects(Rest);
        {error, Reason} -> schema_error(<<"table">>, Name, Reason)
    end;
validate_objects([[<<"index">>, _Name, Definition] | Rest])
  when is_binary(Definition) ->
    case find_forbidden_definition(
           Definition, [{collation, "\\bCOLLATE\\b"},
                        {expression, "[(][^)]*[(]"}]) of
        ok -> validate_objects(Rest);
        {error, Reason} -> schema_error(<<"index">>, _Name, Reason)
    end;
validate_objects([[Type, Name, _Definition] | _Rest])
  when is_binary(Type), is_binary(Name) ->
    schema_error(Type, Name, unsupported_object_type);
validate_objects(Rows) ->
    {error, {invalid_sqlite_schema, Rows}}.

validate_table_definition(Definition) ->
    Forbidden = [{virtual_table, "\\bVIRTUAL\\b"},
                 {default_value, "\\bDEFAULT\\b"},
                 {generated_column_or_create_as, "\\bAS\\b"},
                 {check_constraint, "\\bCHECK\\b"},
                 {collation, "\\bCOLLATE\\b"}],
    find_forbidden_definition(Definition, Forbidden).

find_forbidden_definition(_Definition, []) ->
    ok;
find_forbidden_definition(Definition, [{Reason, Pattern} | Rest]) ->
    case re:run(Definition, Pattern, [caseless, unicode, {capture, none}]) of
        match -> {error, Reason};
        nomatch -> find_forbidden_definition(Definition, Rest)
    end.

schema_error(Type, Name, Reason) ->
    {error, {unsupported_schema_object, Type, Name, Reason}}.
