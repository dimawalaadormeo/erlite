-module(erlite_replica_repair).
-behaviour(gen_server).

-export([start_link/0, configure/2, scan/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TIMEOUT, 15000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

configure(CatalogServer, StorageRoot) ->
    gen_server:call(?MODULE, {configure, CatalogServer, StorageRoot}, infinity).

scan() -> gen_server:call(?MODULE, scan, infinity).

init([]) ->
    State = configured_state(),
    {ok, schedule(State)}.

handle_call({configure, CatalogServer, StorageRoot}, _From, State0) ->
    State = State0#{catalog_server => CatalogServer,
                    storage_root => StorageRoot},
    {reply, scan_all(State), schedule(State)};
handle_call(scan, _From, State) ->
    {reply, scan_all(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) -> {noreply, State}.

handle_info(repair_scan, State) ->
    _ = scan_all(State),
    {noreply, schedule(State#{timer => undefined})};
handle_info(_Info, State) -> {noreply, State}.

configured_state() ->
    Base = #{timer => undefined},
    case {application:get_env(erlite_core, catalog_server),
          application:get_env(erlite_core, storage_root)} of
        {{ok, Catalog}, {ok, Root}} ->
            Base#{catalog_server => Catalog, storage_root => Root};
        _ -> Base
    end.

schedule(State) ->
    case maps:get(timer, State, undefined) of
        undefined ->
            Interval = application:get_env(
                         erlite_core, repair_scan_interval_ms, 5000),
            State#{timer => erlang:send_after(Interval, self(), repair_scan)};
        _ -> State
    end.

scan_all(#{catalog_server := Catalog, storage_root := Root}) ->
    case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
        {ok, #{nodes := Nodes, databases := Databases}} ->
            Results = [scan_database(Database, Nodes, Catalog, Root)
                       || Database <- Databases],
            case [Error || Error = {error, _} <- Results] of
                [] -> ok;
                Errors -> {error, {repair_scan_failed, Errors}}
            end;
        Error -> Error
    end;
scan_all(_) -> {error, repair_not_configured}.

scan_database(Database, Nodes, Catalog, Root) ->
    case cleanup_stale(Database, Catalog, Root) of
        ok ->
            case maps:get(state, Database) of
                ready -> detect_or_repair(Database, Nodes, Catalog);
                _ -> ok
            end;
        Error -> Error
    end.

detect_or_repair(#{movement := _}, _Nodes, _Catalog) ->
    reconcile_movement();
detect_or_repair(Database = #{replicas := Replicas}, Nodes, Catalog) ->
    Unhealthy = [ServerId || ServerId <- Replicas,
                              not replica_healthy(ServerId)],
    case {maps:find(repair, Database), Unhealthy} of
        {{ok, Repair = #{phase := waiting}}, []} ->
            erlite_catalog:clear_database_under_replicated(
              Catalog, maps:get(database_id, Database),
              maps:get(operation_id, Repair), maps:get(generation, Database),
              ?TIMEOUT);
        {{ok, Repair = #{phase := waiting, failed := Failed}}, [Failed]} ->
            maybe_start_repair(Database, Repair, Nodes, Catalog);
        {{ok, Repair = #{phase := waiting, failed := Failed}}, Unhealthy} ->
            case lists:member(Failed, Unhealthy) of
                true -> ok;
                false -> erlite_catalog:clear_database_under_replicated(
                           Catalog, maps:get(database_id, Database),
                           maps:get(operation_id, Repair),
                           maps:get(generation, Database), ?TIMEOUT)
            end;
        {{ok, _Repair}, _} -> ok;
        {error, [Failed]} -> mark_under_replicated(Database, Failed, Catalog);
        {error, _} -> ok
    end.

mark_under_replicated(Database, Failed, Catalog) ->
    erlite_catalog:mark_database_under_replicated(
      Catalog, maps:get(database_id, Database), crypto:strong_rand_bytes(16),
      maps:get(generation, Database), Failed,
      erlang:system_time(millisecond), ?TIMEOUT).

maybe_start_repair(Database, Repair, Nodes, Catalog) ->
    Grace = application:get_env(erlite_core, repair_grace_period_ms, 30000),
    Age = erlang:system_time(millisecond) - maps:get(detected_at, Repair),
    case Age >= Grace of
        false -> ok;
        true ->
            case choose_replacement(Database, Nodes) of
                {ok, TargetNode} ->
                    Replacement = repair_server_id(
                                    maps:get(database_id, Database),
                                    maps:get(generation, Database) + 1,
                                    TargetNode),
                    case erlite_catalog:prepare_database_repair(
                           Catalog, maps:get(database_id, Database),
                           maps:get(operation_id, Repair),
                           maps:get(generation, Database),
                           maps:get(failed, Repair), Replacement, ?TIMEOUT) of
                        ok -> reconcile_movement();
                        Error -> Error
                    end;
                Error -> Error
            end
    end.

choose_replacement(#{database_id := DatabaseId, replicas := Replicas}, Nodes) ->
    choose_replacement(DatabaseId, Replicas, Nodes).

choose_replacement(DatabaseId, Replicas, Nodes) ->
    ReplicaNodes = [Node || {_, Node} <- Replicas],
    Options = application:get_env(erlite_core, placement_options, #{}),
    Candidates = lists:sort(
                   [Node || #{state := active, server_id := {_, Node}} <- Nodes,
                            not lists:member(Node, ReplicaNodes),
                            erlite_node_health:healthy(Node),
                            erlite_placement:can_place(DatabaseId, Node,
                                                       Options)]),
    case Candidates of
        [Node | _] -> {ok, Node};
        [] -> {error, no_repair_target}
    end.

repair_server_id(DatabaseId, Generation, TargetNode) ->
    Digest = binary_to_list(erlite_sqlite_database:digest(DatabaseId)),
    {list_to_atom("erlite_db_" ++ Digest ++ "_g" ++
                  integer_to_list(Generation) ++ "_repair_replacement"),
     TargetNode}.

replica_healthy({Name, Node}) ->
    erlite_node_health:healthy(Node) andalso
        case rpc:call(Node, ra_directory, where_is, [default, Name], 2000) of
            Pid when is_pid(Pid) -> true;
            _ -> false
        end.

reconcile_movement() ->
    case erlite_database_lifecycle:reconcile() of
        ok -> ok;
        {error, _} = Error -> Error
    end.

cleanup_stale(#{stale_replicas := Stale, database_id := DatabaseId,
                generation := Generation}, Catalog, Root) ->
    cleanup_stale_list(Stale, DatabaseId, Generation, Catalog, Root);
cleanup_stale(_Database, _Catalog, _Root) -> ok.

cleanup_stale_list([], _DatabaseId, _Generation, _Catalog, _Root) -> ok;
cleanup_stale_list([#{server_id := ServerId, generation := StaleGeneration}
                    | Rest], DatabaseId, Generation,
                   Catalog, Root) ->
    case erlite_node_health:healthy(element(2, ServerId)) of
        false -> ok;
        true ->
            case erlite_database:cleanup_stale_replica(
                   DatabaseId, Root, ServerId) of
                ok ->
                    case erlite_catalog:clear_stale_replica(
                           Catalog, DatabaseId, ServerId, StaleGeneration,
                           Generation,
                           ?TIMEOUT) of
                        ok -> cleanup_stale_list(Rest, DatabaseId, Generation,
                                                 Catalog, Root);
                        Error -> Error
                    end;
                Error -> Error
            end
    end.
