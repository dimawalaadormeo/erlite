-module(erlite_sqlite_reader).
-behaviour(gen_server).

-export([start_link/2, query/5, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {connection :: erlite_sqlite:connection()}).

-spec start_link(file:filename_all(), binary()) -> gen_server:start_ret().
start_link(StorageRoot, DatabaseId) ->
    gen_server:start_link(?MODULE, {StorageRoot, DatabaseId}, []).

-spec query(pid(), binary(), erlite_sqlite_adapter:params(), pid(), reference()) ->
    ok.
query(Pid, Sql, Params, Pool, JobRef) ->
    gen_server:cast(Pid, {query, Sql, Params, Pool, JobRef}).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:stop(Pid).

init({StorageRoot, DatabaseId}) ->
    case erlite_sqlite_database:open(StorageRoot, DatabaseId) of
        {ok, Connection} ->
            case erlite_sqlite:execute(
                   Connection, <<"PRAGMA query_only = ON">>, []) of
                {ok, _} -> {ok, #state{connection = Connection}};
                {error, Reason} ->
                    _ = erlite_sqlite:close(Connection),
                    {stop, {query_only_enable_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast({query, Sql, Params, Pool, JobRef},
            State = #state{connection = Connection}) ->
    Result = erlite_sqlite:query(Connection, Sql, Params),
    Pool ! {read_complete, self(), JobRef, Result},
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    _ = erlite_sqlite:close(Connection),
    ok.
