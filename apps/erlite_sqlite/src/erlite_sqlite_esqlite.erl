-module(erlite_sqlite_esqlite).
-behaviour(erlite_sqlite_adapter).

-export([open/2, close/1, execute/3, query/3, transaction/2]).

-spec open(file:filename_all(), erlite_sqlite_adapter:open_options()) ->
    {ok, esqlite3:esqlite3()} | {error, term()}.
open(Path, Options) when map_size(Options) =:= 0 ->
    esqlite3:open(filename_string(Path));
open(_Path, Options) ->
    {error, {unsupported_open_options, Options}}.

-spec close(esqlite3:esqlite3()) -> ok | {error, term()}.
close(Connection) ->
    esqlite3:close(Connection).

-spec execute(esqlite3:esqlite3(), binary(), erlite_sqlite_adapter:params()) ->
    {ok, erlite_sqlite_adapter:execute_result()} | {error, term()}.
execute(Connection, Sql, Params) ->
    case esqlite3:q(Connection, Sql, to_esqlite_params(Params)) of
        Rows when is_list(Rows) ->
            {ok, #{changes => esqlite3:changes(Connection),
                   last_insert_rowid => esqlite3:last_insert_rowid(Connection)}};
        {error, _Code} = Error ->
            Error
    end.

-spec query(esqlite3:esqlite3(), binary(), erlite_sqlite_adapter:params()) ->
    {ok, erlite_sqlite_adapter:query_result()} | {error, term()}.
query(Connection, Sql, Params) ->
    case prepare_and_bind(Connection, Sql, Params) of
        {ok, Statement} ->
            Columns = esqlite3:column_names(Statement),
            case esqlite3:fetchall(Statement) of
                Rows when is_list(Rows) ->
                    {ok, #{columns => Columns, rows => normalize_rows(Rows)}};
                {error, _Code} = Error ->
                    Error
            end;
        {error, _Code} = Error ->
            Error
    end.

-spec transaction(esqlite3:esqlite3(), [erlite_sqlite_adapter:statement()]) ->
    {ok, [erlite_sqlite_adapter:statement_result()]} | {error, term()}.
transaction(Connection, Statements) ->
    case esqlite3:exec(Connection, <<"BEGIN IMMEDIATE">>) of
        ok ->
            finish_transaction(Connection, run_statements(Connection, Statements, []));
        {error, _Code} = Error ->
            Error
    end.

finish_transaction(Connection, {ok, Results}) ->
    case esqlite3:exec(Connection, <<"COMMIT">>) of
        ok ->
            {ok, Results};
        {error, _Code} = Error ->
            _ = esqlite3:exec(Connection, <<"ROLLBACK">>),
            Error
    end;
finish_transaction(Connection, {error, _Reason} = Error) ->
    _ = esqlite3:exec(Connection, <<"ROLLBACK">>),
    Error.

run_statements(_Connection, [], Results) ->
    {ok, lists:reverse(Results)};
run_statements(Connection, [{execute, Sql, Params} | Rest], Results) ->
    case execute(Connection, Sql, Params) of
        {ok, Result} -> run_statements(Connection, Rest, [Result | Results]);
        {error, _Reason} = Error -> Error
    end;
run_statements(Connection, [{query, Sql, Params} | Rest], Results) ->
    case query(Connection, Sql, Params) of
        {ok, Result} -> run_statements(Connection, Rest, [Result | Results]);
        {error, _Reason} = Error -> Error
    end.

prepare_and_bind(Connection, Sql, Params) ->
    case esqlite3:prepare(Connection, Sql) of
        {ok, Statement} ->
            case esqlite3:bind(Statement, to_esqlite_params(Params)) of
                ok -> {ok, Statement};
                {error, _Code} = Error -> Error
            end;
        {error, _Code} = Error ->
            Error
    end.

to_esqlite_params(Params) ->
    [case Value of null -> undefined; _ -> Value end || Value <- Params].

normalize_rows(Rows) ->
    [[case Value of undefined -> null; _ -> Value end || Value <- Row] || Row <- Rows].

filename_string(Path) when is_binary(Path) ->
    unicode:characters_to_list(Path);
filename_string(Path) ->
    filename:flatten(Path).

