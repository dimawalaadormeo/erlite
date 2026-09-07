-module(erlite_api_query_policy).

-export([validate/1]).

validate(Sql) when is_binary(Sql), byte_size(Sql) > 0 ->
    Upper = string:uppercase(Sql),
    case re:run(Upper, <<"^\\s*SELECT\\b">>, [{capture, none}, unicode]) =:= match
         andalso not forbidden(Upper) of
        true -> ok;
        false -> {error, unsafe_query}
    end;
validate(_) -> {error, unsafe_query}.

forbidden(Sql) ->
    lists:any(fun(Token) -> binary:match(Sql, Token) =/= nomatch end,
              [<<";">>, <<"--">>, <<"/*">>, <<"*/">>,
               <<"__ERLITE_">>, <<"ATTACH">>, <<"DETACH">>,
               <<"PRAGMA">>, <<"INSERT">>, <<"UPDATE">>, <<"DELETE">>,
               <<"CREATE">>, <<"DROP">>, <<"ALTER">>, <<"REPLACE">>,
               <<"VACUUM">>, <<"REINDEX">>, <<"ANALYZE">>]).
