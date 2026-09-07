-module(erlite_databases).
-behaviour(gen_server).

-export([start_link/0, create/2, ensure/2, delete/1, delete_recorded/2,
         list/0, status/1,
         write/3, query/4, cool/1, add_replacement/5, remove_source/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(ROUTES, erlite_database_routes).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(DatabaseId, Options) -> gen_server:call(?MODULE, {create, DatabaseId, Options}, infinity).
ensure(DatabaseId, Options) -> gen_server:call(?MODULE, {ensure, DatabaseId, Options}, infinity).
delete(DatabaseId) -> gen_server:call(?MODULE, {delete, DatabaseId}, infinity).
delete_recorded(DatabaseId, Options) ->
    gen_server:call(?MODULE, {delete_recorded, DatabaseId, Options}, infinity).
list() ->
    case route_entries() of
        {ok, Entries} -> {ok, lists:sort([DatabaseId || {DatabaseId, _} <- Entries])};
        Error -> Error
    end.
status(DatabaseId) -> call_database(DatabaseId, status).
write(DatabaseId, Command, Timeout) ->
    call_database(DatabaseId, {write, Command, Timeout}).
query(DatabaseId, Sql, Params, Timeout) ->
    call_database(DatabaseId, {query, Sql, Params, Timeout}).
cool(DatabaseId) -> call_database(DatabaseId, cool).
add_replacement(DatabaseId, Source, Replacement, Generation, Timeout) ->
    gen_server:call(?MODULE,
                    {add_replacement, DatabaseId, Source, Replacement,
                     Generation, Timeout}, infinity).
remove_source(DatabaseId, Source, Replacement, Timeout) ->
    gen_server:call(?MODULE,
                    {remove_source, DatabaseId, Source, Replacement, Timeout},
                    infinity).

call_database(DatabaseId, Request) ->
    case lookup_route(DatabaseId) of
        {ok, Pid} -> database_call(Pid, Request);
        Error -> Error
    end.

init([]) ->
    ?ROUTES = ets:new(?ROUTES, [named_table, protected, set,
                                {read_concurrency, true}]),
    {ok, reconcile_children()}.

handle_call({create, DatabaseId, Options}, _From, State) ->
    case maps:is_key(DatabaseId, State) of
        true -> {reply, {error, database_exists}, State};
        false -> create_database(DatabaseId, Options, State)
    end;
handle_call({ensure, DatabaseId, Options}, _From, State) ->
    case maps:find(DatabaseId, State) of
        {ok, #{pid := Pid, server_ids := ServerIds}} ->
            case maps:get(server_ids, Options, undefined) of
                ServerIds -> {reply, {ok, Pid}, State};
                _ -> {reply, {error, database_placement_conflict}, State}
            end;
        error -> create_database(DatabaseId, Options#{ensure_existing => true}, State)
    end;
handle_call({delete, DatabaseId}, _From, State) ->
    case maps:find(DatabaseId, State) of
        error -> {reply, ok, State};
        {ok, #{pid := Pid, monitor := Monitor}} ->
            ets:delete(?ROUTES, DatabaseId),
            Reply = database_call(Pid, delete),
            erlang:demonitor(Monitor, [flush]),
            {reply, Reply, maps:remove(DatabaseId, State)}
    end;
handle_call({delete_recorded, DatabaseId, Options}, _From, State) ->
    case maps:find(DatabaseId, State) of
        {ok, #{pid := Pid, monitor := Monitor, server_ids := ServerIds}} ->
            case maps:get(server_ids, Options, undefined) of
                ServerIds ->
                    ets:delete(?ROUTES, DatabaseId),
                    Reply = database_call(Pid, delete),
                    erlang:demonitor(Monitor, [flush]),
                    {reply, Reply, maps:remove(DatabaseId, State)};
                _ -> {reply, {error, database_placement_conflict}, State}
            end;
        error ->
            {reply, erlite_database:delete_resources(DatabaseId, Options), State}
    end;
handle_call({add_replacement, DatabaseId, Source, Replacement, Generation,
             Timeout}, _From, State) ->
    movement_call(DatabaseId,
                  {add_replacement, Source, Replacement, Generation, Timeout},
                  State);
handle_call({remove_source, DatabaseId, Source, Replacement, Timeout},
            _From, State) ->
    movement_call(DatabaseId,
                  {remove_source, Source, Replacement, Timeout}, State);
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) -> {noreply, State}.

handle_info({'DOWN', Monitor, process, Pid, _Reason}, State) ->
    remove_route(Pid),
    {noreply, maps:filter(
                fun(_Id, Entry) ->
                        maps:get(pid, Entry) =/= Pid orelse
                            maps:get(monitor, Entry) =/= Monitor
                end, State)};
handle_info(_Info, State) -> {noreply, State}.

create_database(DatabaseId, Options, State) ->
    case validate_server_ids(Options, State) of
        ok ->
            case erlite_database_sup:start_database(DatabaseId, Options) of
                {ok, Pid} ->
                    Monitor = erlang:monitor(process, Pid),
                    Entry = #{pid => Pid, monitor => Monitor,
                              server_ids => maps:get(server_ids, Options)},
                    true = ets:insert(?ROUTES, {DatabaseId, Pid}),
                    {reply, {ok, Pid}, State#{DatabaseId => Entry}};
                {error, _Reason} = Error -> {reply, Error, State}
            end;
        {error, _Reason} = Error -> {reply, Error, State}
    end.

validate_server_ids(#{server_ids := ServerIds}, State)
  when is_list(ServerIds), length(ServerIds) =:= 3 ->
    Used = lists:append([maps:get(server_ids, Entry) || Entry <- maps:values(State)]),
    case lists:any(fun(Id) -> lists:member(Id, Used) end, ServerIds) of
        true -> {error, raft_server_id_in_use};
        false -> ok
    end;
validate_server_ids(_Options, _State) -> {error, invalid_server_ids}.

lookup_route(DatabaseId) ->
    try ets:lookup(?ROUTES, DatabaseId) of
        [{DatabaseId, Pid}] when is_pid(Pid) -> {ok, Pid};
        [] -> {error, database_not_found}
    catch
        error:badarg -> {error, database_registry_unavailable}
    end.

route_entries() ->
    try {ok, ets:tab2list(?ROUTES)}
    catch
        error:badarg -> {error, database_registry_unavailable}
    end.

database_call(Pid, Request) ->
    database_call(Pid, Request, infinity).

database_call(Pid, Request, Timeout) ->
    try gen_server:call(Pid, Request, Timeout)
    catch
        exit:Reason -> {error, {database_unavailable, Reason}}
    end.

movement_call(DatabaseId, Request, State) ->
    case maps:find(DatabaseId, State) of
        {ok, Entry = #{pid := Pid}} ->
            case database_call(Pid, Request) of
                ok ->
                    case database_call(Pid, registry_metadata, 5000) of
                        {ok, #{server_ids := ServerIds}} ->
                            {reply, ok,
                             State#{DatabaseId => Entry#{server_ids =>
                                                             ServerIds}}};
                        Error -> {reply, Error, State}
                    end;
                Error -> {reply, Error, State}
            end;
        error -> {reply, {error, database_not_found}, State}
    end.

remove_route(Pid) ->
    ets:match_delete(?ROUTES, {'_', Pid}).

reconcile_children() ->
    lists:foldl(
      fun({DatabaseId, Pid, worker, _Modules}, State) when is_pid(Pid) ->
              case database_call(Pid, registry_metadata, 5000) of
                  {ok, #{database_id := DatabaseId,
                         server_ids := ServerIds}} ->
                      Monitor = erlang:monitor(process, Pid),
                      true = ets:insert(?ROUTES, {DatabaseId, Pid}),
                      State#{DatabaseId => #{pid => Pid, monitor => Monitor,
                                             server_ids => ServerIds}};
                  error -> State
              end;
         (_, State) -> State
      end, #{}, supervisor:which_children(erlite_database_sup)).
