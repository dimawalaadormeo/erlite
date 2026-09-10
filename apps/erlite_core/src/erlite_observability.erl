-module(erlite_observability).
-behaviour(gen_server).

-export([start_link/0, record/1, record/2, snapshot/0, health/0, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, erlite_observability_counters).
-define(CATALOG_TIMEOUT, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Event names are deliberately atoms from call sites, rather than arbitrary
%% client labels.  This keeps the in-VM metric cardinality bounded.
record(Event) -> record(Event, 1).

record(Event, Increment)
  when is_atom(Event), is_integer(Increment), Increment > 0 ->
    try ets:update_counter(?TABLE, Event, {2, Increment}, {Event, 0}) of
        _ -> ok
    catch
        error:badarg -> ok
    end;
record(_, _) -> {error, invalid_metric}.

snapshot() ->
    try build_snapshot() of
        Snapshot -> Snapshot
    catch
        error:badarg -> #{status => #{status => starting}, counters => #{}}
    end.

build_snapshot() ->
    Counters = maps:from_list(ets:tab2list(?TABLE)),
    Memory = maps:from_list(erlang:memory()),
    #{status => health(),
      counters => Counters,
      databases => database_metrics(),
      vm => #{process_count => erlang:system_info(process_count),
              process_limit => erlang:system_info(process_limit),
              run_queue => erlang:statistics(run_queue),
              memory_bytes => maps:get(total, Memory)}}.

health() ->
    Workers = [erlite_database_sup, erlite_databases,
               erlite_database_router, erlite_database_lifecycle,
               erlite_replica_repair, erlite_rebalancer,
               erlite_fleet_migrations],
    Missing = [Name || Name <- Workers, not is_pid(whereis(Name))],
    Catalog = catalog_health(),
    Status = case {Missing, Catalog} of
                 {[], ready} -> ready;
                 _ -> degraded
             end,
    #{status => Status, catalog => Catalog, missing_workers => Missing}.

reset() -> gen_server:call(?MODULE, reset).

init([]) ->
    _ = ets:new(?TABLE, [named_table, set, public,
                         {read_concurrency, true},
                         {write_concurrency, true}]),
    {ok, #{}}.

handle_call(reset, _From, State) ->
    true = ets:delete_all_objects(?TABLE),
    {reply, ok, State};
handle_call(_Request, _From, State) -> {reply, {error, unsupported}, State}.

handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

catalog_health() ->
    case application:get_env(erlite_core, catalog_server) of
        {ok, Catalog} ->
            case erlite_catalog:status(Catalog, ?CATALOG_TIMEOUT, consistent) of
                {ok, #{nodes := Nodes}} ->
                    Active = length([ok || #{state := active} <- Nodes]),
                    case Active >= 3 of true -> ready; false -> under_replicated end;
                {timeout, _} -> unavailable;
                {error, _} -> unavailable
            end;
        undefined -> not_configured
    end.

database_metrics() ->
    Result = try erlite_databases:list()
             catch exit:_ -> unavailable
             end,
    case Result of
        {ok, DatabaseIds} ->
            Statuses = [Status || DatabaseId <- DatabaseIds,
                                  {ok, Status} <- [erlite_databases:status(DatabaseId)]],
            #{count => length(DatabaseIds),
              active => length([ok || #{mode := active} <- Statuses]),
              cold => length([ok || #{mode := cold} <- Statuses]),
              sqlite_bytes => lists:sum(
                                  [maps:get(sqlite_bytes, S, 0) || S <- Statuses])};
        _ -> #{unavailable => true}
    end.
