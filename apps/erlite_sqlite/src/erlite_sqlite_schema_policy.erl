-module(erlite_sqlite_schema_policy).

-export([validate/1]).

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
validate_objects([[<<"index">>, Name, _Definition] | _Rest])
  when is_binary(Name) ->
    schema_error(<<"index">>, Name, explicit_index);
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
