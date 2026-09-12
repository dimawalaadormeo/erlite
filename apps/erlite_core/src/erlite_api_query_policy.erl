-module(erlite_api_query_policy).

-export([validate/1]).

validate(Sql) when is_binary(Sql), byte_size(Sql) > 0 ->
    case redact_literals(string:uppercase(Sql), <<>>) of
        {ok, StructuralSql} ->
            case re:run(StructuralSql, <<"^\\s*SELECT\\b">>,
                        [{capture, none}, unicode]) =:= match
                 andalso not forbidden(StructuralSql) of
                true -> ok;
                false -> {error, unsafe_query}
            end;
        error -> {error, unsafe_query}
    end;
validate(_) -> {error, unsafe_query}.

forbidden(Sql) ->
    lists:any(fun(Token) -> keyword(Sql, Token) end,
              [<<"__ERLITE_[A-Z0-9_]*">>, <<"SQLITE_MASTER">>,
               <<"SQLITE_SCHEMA">>, <<"LOAD_EXTENSION">>,
               <<"ATTACH">>, <<"DETACH">>,
               <<"PRAGMA">>, <<"INSERT">>, <<"UPDATE">>, <<"DELETE">>,
               <<"CREATE">>, <<"DROP">>, <<"ALTER">>, <<"REPLACE">>,
               <<"VACUUM">>, <<"REINDEX">>, <<"ANALYZE">>])
        orelse binary:match(Sql, <<";">>) =/= nomatch
        orelse binary:match(Sql, <<"--">>) =/= nomatch
        orelse binary:match(Sql, <<"/*">>) =/= nomatch
        orelse binary:match(Sql, <<"*/">>) =/= nomatch.

keyword(Sql, Pattern) ->
    Regex = <<"(?:^|[^A-Z0-9_])(?:", Pattern/binary,
              ")(?:$|[^A-Z0-9_])">>,
    re:run(Sql, Regex, [{capture, none}]) =:= match.

%% Values inside SQL string literals cannot change statement structure. Remove
%% them before keyword inspection so ordinary data does not trigger the gate.
redact_literals(<<>>, Acc) -> {ok, Acc};
redact_literals(<<$',$', Rest/binary>>, Acc) ->
    redact_literals(Rest, <<Acc/binary, "  ">>);
redact_literals(<<$', Rest/binary>>, Acc) ->
    redact_string(Rest, <<Acc/binary, $ >>);
redact_literals(<<C, Rest/binary>>, Acc) ->
    redact_literals(Rest, <<Acc/binary, C>>).

redact_string(<<$',$', Rest/binary>>, Acc) ->
    redact_string(Rest, <<Acc/binary, "  ">>);
redact_string(<<$', Rest/binary>>, Acc) ->
    redact_literals(Rest, <<Acc/binary, $ >>);
redact_string(<<_C, Rest/binary>>, Acc) ->
    redact_string(Rest, <<Acc/binary, $ >>);
redact_string(<<>>, _Acc) -> error.
