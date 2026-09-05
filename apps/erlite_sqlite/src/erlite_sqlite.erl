-module(erlite_sqlite).

-export([open/1, open/2, close/1, execute/3, query/3, transaction/2]).

-export_type([connection/0]).

-opaque connection() :: {module(), erlite_sqlite_adapter:connection()}.
-type result(Value) :: {ok, Value} | {error, term()}.

-spec open(file:filename_all()) -> result(connection()).
open(Path) ->
    open(Path, #{}).

-spec open(file:filename_all(), map()) -> result(connection()).
open(Path, Options) when is_map(Options) ->
    Backend = maps:get(adapter, Options, configured_adapter()),
    case validate_adapter(Backend) of
        ok ->
            case Backend:open(Path, maps:remove(adapter, Options)) of
                {ok, BackendConnection} ->
                    {ok, {Backend, BackendConnection}};
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

-spec close(connection()) -> ok | {error, term()}.
close({Backend, BackendConnection}) ->
    Backend:close(BackendConnection).

-spec execute(connection(), binary(), erlite_sqlite_adapter:params()) ->
    result(erlite_sqlite_adapter:execute_result()).
execute({Backend, BackendConnection}, Sql, Params) ->
    Backend:execute(BackendConnection, Sql, Params).

-spec query(connection(), binary(), erlite_sqlite_adapter:params()) ->
    result(erlite_sqlite_adapter:query_result()).
query({Backend, BackendConnection}, Sql, Params) ->
    Backend:query(BackendConnection, Sql, Params).

-spec transaction(connection(), [erlite_sqlite_adapter:statement()]) ->
    result([erlite_sqlite_adapter:statement_result()]).
transaction({Backend, BackendConnection}, Statements) ->
    Backend:transaction(BackendConnection, Statements).

-spec configured_adapter() -> module().
configured_adapter() ->
    application:get_env(erlite_sqlite, adapter, erlite_sqlite_esqlite).

-spec validate_adapter(term()) -> ok | {error, {invalid_adapter, term()}}.
validate_adapter(Backend) when is_atom(Backend), Backend =/= undefined ->
    RequiredCallbacks = [{open, 2},
                         {close, 1},
                         {execute, 3},
                         {query, 3},
                         {transaction, 2}],
    case code:ensure_loaded(Backend) of
        {module, Backend} ->
            case lists:all(fun({Function, Arity}) ->
                                   erlang:function_exported(Backend, Function, Arity)
                           end,
                           RequiredCallbacks) of
                true -> ok;
                false -> {error, {invalid_adapter, Backend}}
            end;
        {error, _Reason} ->
            {error, {invalid_adapter, Backend}}
    end;
validate_adapter(Backend) ->
    {error, {invalid_adapter, Backend}}.
