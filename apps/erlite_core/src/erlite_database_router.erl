-module(erlite_database_router).
-behaviour(gen_server).

-export([start_link/0, configure/1, resolve/2, leader/2, cached/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CACHE, erlite_database_route_cache).
-define(CONFIG_KEY, '$catalog').

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

configure(ServerRef) ->
    gen_server:call(?MODULE, {configure, ServerRef}).

resolve(DatabaseId, Timeout) ->
    case catalog_config() of
        {ok, ServerRef, Epoch} ->
            resolve_from_catalog(ServerRef, Epoch, DatabaseId, Timeout);
        Error -> Error
    end.

leader(DatabaseId, Timeout) ->
    case catalog_config() of
        {ok, ServerRef, Epoch} ->
            resolve_leader(ServerRef, Epoch, DatabaseId, Timeout);
        Error -> Error
    end.

cached(DatabaseId) ->
    try ets:lookup(?CACHE, DatabaseId) of
        [{DatabaseId, Generation, Database, Leader}] ->
            {ok, #{generation => Generation, database => Database,
                   leader => Leader}};
        [] -> {error, route_not_cached}
    catch
        error:badarg -> {error, router_unavailable}
    end.

init([]) ->
    ?CACHE = ets:new(?CACHE, [named_table, protected, set,
                              {read_concurrency, true}]),
    Epoch = make_ref(),
    case application:get_env(erlite_core, catalog_server) of
        {ok, ServerRef} ->
            true = ets:insert(?CACHE, {?CONFIG_KEY, ServerRef, Epoch}),
            {ok, #{catalog_server => ServerRef, epoch => Epoch}};
        undefined -> {ok, #{catalog_server => undefined, epoch => Epoch}}
    end.

handle_call({configure, ServerRef}, _From, State) ->
    ok = application:set_env(erlite_core, catalog_server, ServerRef),
    ets:delete_all_objects(?CACHE),
    Epoch = make_ref(),
    true = ets:insert(?CACHE, {?CONFIG_KEY, ServerRef, Epoch}),
    {reply, ok, State#{catalog_server => ServerRef, epoch => Epoch}};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast({cache, Epoch, DatabaseId, Database, Leader},
            State = #{epoch := Epoch}) ->
    Generation = maps:get(generation, Database),
    case ets:lookup(?CACHE, DatabaseId) of
        [{DatabaseId, Current, _OldDatabase, _OldLeader}]
          when Current > Generation -> ok;
        _ -> true = ets:insert(
                      ?CACHE, {DatabaseId, Generation, Database, Leader})
    end,
    {noreply, State};
handle_cast({evict, Epoch, DatabaseId}, State = #{epoch := Epoch}) ->
    ets:delete(?CACHE, DatabaseId),
    {noreply, State};
handle_cast(_Request, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

catalog_config() ->
    try ets:lookup(?CACHE, ?CONFIG_KEY) of
        [{?CONFIG_KEY, ServerRef, Epoch}] -> {ok, ServerRef, Epoch};
        [] -> {error, catalog_not_configured}
    catch
        error:badarg -> {error, router_unavailable}
    end.

resolve_from_catalog(ServerRef, Epoch, DatabaseId, Timeout) ->
    case erlite_catalog:database(
           ServerRef, DatabaseId, Timeout, consistent) of
        {ok, Database = #{state := ready}} ->
            gen_server:cast(?MODULE,
                            {cache, Epoch, DatabaseId, Database, undefined}),
            {ok, Database};
        {ok, #{state := Lifecycle}} ->
            gen_server:cast(?MODULE, {evict, Epoch, DatabaseId}),
            {error, {database_not_ready, Lifecycle}};
        {error, database_not_found} = Error ->
            gen_server:cast(?MODULE, {evict, Epoch, DatabaseId}),
            Error;
        Other -> Other
    end.

resolve_leader(ServerRef, Epoch, DatabaseId, Timeout) ->
    case resolve_from_catalog(ServerRef, Epoch, DatabaseId, Timeout) of
        {ok, Database = #{replicas := Replicas}} ->
            case ra:members(Replicas, Timeout) of
                {ok, Members, Leader} ->
                    case lists:member(Leader, Members) andalso
                         lists:member(Leader, Replicas) of
                        true ->
                            gen_server:cast(
                              ?MODULE,
                              {cache, Epoch, DatabaseId, Database, Leader}),
                            {ok, #{database => Database, leader => Leader}};
                        false -> {error, invalid_database_leader}
                    end;
                Other -> Other
            end;
        Error -> Error
    end.
