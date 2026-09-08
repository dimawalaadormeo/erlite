-module(erlite_rebalancer).
-behaviour(gen_server).

-export([start_link/0, configure/2, scan/0, plan/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TIMEOUT, 15000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
configure(CatalogServer, StorageRoot) ->
    gen_server:call(?MODULE, {configure, CatalogServer, StorageRoot}, infinity).
scan() -> gen_server:call(?MODULE, scan, infinity).

init([]) -> {ok, schedule(configured_state())}.

handle_call({configure, CatalogServer, StorageRoot}, _From, State0) ->
    State = State0#{catalog_server => CatalogServer,
                    storage_root => StorageRoot},
    {reply, scan_all(State), schedule(State)};
handle_call(scan, _From, State) -> {reply, scan_all(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) -> {noreply, State}.
handle_info(rebalance_scan, State) ->
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
                         erlite_core, rebalance_scan_interval_ms, 10000),
            State#{timer => erlang:send_after(Interval, self(),
                                              rebalance_scan)};
        _ -> State
    end.

scan_all(#{catalog_server := Catalog}) ->
    case ra:members(Catalog, ?TIMEOUT) of
        {ok, _Members, Leader = {_Name, LeaderNode}} ->
            case LeaderNode =:= node() orelse Catalog =:= Leader of
                true -> scan_as_controller(Catalog);
                false -> ok
            end;
        {error, _} = Error -> Error;
        {timeout, _} = Timeout -> Timeout;
        Other -> {error, {catalog_members_failed, Other}}
    end;
scan_all(_) -> {error, rebalancer_not_configured}.

scan_as_controller(Catalog) ->
    case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
        {ok, #{nodes := NodeRecords, databases := Databases}} ->
            Nodes = lists:sort(
                      [Node || #{state := active,
                                 server_id := {_, Node}} <- NodeRecords,
                               node_healthy(Node)]),
            Limit = application:get_env(
                      erlite_core, rebalance_max_migrations_per_scan, 1),
            execute(plan(Databases, Nodes, Limit), []);
        Error -> Error
    end.

node_healthy(Node) when Node =:= node() -> true;
node_healthy(Node) -> net_adm:ping(Node) =:= pong.

execute([], []) -> ok;
execute([], Errors) -> {error, {rebalance_failed, lists:reverse(Errors)}};
execute([{DatabaseId, Source, Target} | Rest], Errors) ->
    case erlite_database_lifecycle:move(DatabaseId, Source, Target) of
        ok -> execute(Rest, Errors);
        Error -> execute(Rest, [{DatabaseId, Error} | Errors])
    end.

-spec plan([map()], [node()], non_neg_integer()) ->
    [{binary(), term(), node()}].
plan(Databases, ActiveNodes, Limit)
  when is_list(Databases), is_list(ActiveNodes),
       is_integer(Limit), Limit >= 0 ->
    Stable = lists:sort(
               fun(A, B) -> maps:get(database_id, A) =<
                                maps:get(database_id, B) end,
               [D || D = #{state := ready, replicas := Replicas} <- Databases,
                     not maps:is_key(movement, D),
                     not maps:is_key(repair, D),
                     replicas_on_active_nodes(Replicas, ActiveNodes)]),
    plan_loop(Stable, replica_counts(Databases, ActiveNodes), ActiveNodes,
              Limit, []).

plan_loop(_Databases, _Counts, _Nodes, 0, Acc) -> lists:reverse(Acc);
plan_loop(Databases, Counts, Nodes, Remaining, Acc) ->
    case choose_move(Databases, Counts, Nodes) of
        none -> lists:reverse(Acc);
        {Database, Source, Target} ->
            DatabaseId = maps:get(database_id, Database),
            SourceNode = element(2, Source),
            Updated = Counts#{SourceNode => maps:get(SourceNode, Counts) - 1,
                              Target => maps:get(Target, Counts) + 1},
            plan_loop(lists:delete(Database, Databases), Updated, Nodes,
                      Remaining - 1,
                      [{DatabaseId, Source, Target} | Acc])
    end.

choose_move(Databases, Counts, Nodes) ->
    choose_source(nodes_by_load(Nodes, Counts, descending),
                  nodes_by_load(Nodes, Counts, ascending), Databases, Counts).

choose_source([], _Targets, _Databases, _Counts) -> none;
choose_source([SourceNode | Sources], Targets, Databases, Counts) ->
    case choose_target(SourceNode, Targets, Databases, Counts) of
        none -> choose_source(Sources, Targets, Databases, Counts);
        Move -> Move
    end.

choose_target(_SourceNode, [], _Databases, _Counts) -> none;
choose_target(SourceNode, [Target | Targets], Databases, Counts) ->
    case maps:get(SourceNode, Counts) - maps:get(Target, Counts) > 1 of
        false -> none;
        true ->
            case database_for_move(Databases, SourceNode, Target) of
                none -> choose_target(SourceNode, Targets, Databases, Counts);
                {Database, Source} -> {Database, Source, Target}
            end
    end.

database_for_move([], _SourceNode, _Target) -> none;
database_for_move([Database = #{replicas := Replicas} | Rest], SourceNode,
                  Target) ->
    case {server_on_node(Replicas, SourceNode), server_on_node(Replicas, Target)} of
        {{ok, Source}, error} -> {Database, Source};
        _ -> database_for_move(Rest, SourceNode, Target)
    end.

server_on_node(Replicas, Node) ->
    case [Server || Server = {_, ReplicaNode} <- Replicas,
                    ReplicaNode =:= Node] of
        [Server | _] -> {ok, Server};
        [] -> error
    end.

replicas_on_active_nodes(Replicas, ActiveNodes) ->
    lists:all(fun({_, Node}) -> lists:member(Node, ActiveNodes) end, Replicas).

replica_counts(Databases, ActiveNodes) ->
    Empty = maps:from_list([{Node, 0} || Node <- ActiveNodes]),
    lists:foldl(
      fun(#{state := ready, replicas := Replicas}, Counts) ->
              lists:foldl(
                fun({_, Node}, Inner) ->
                        case maps:is_key(Node, Inner) of
                            true -> Inner#{Node => maps:get(Node, Inner) + 1};
                            false -> Inner
                        end
                end, Counts, Replicas);
         (_, Counts) -> Counts
      end, Empty, Databases).

nodes_by_load(Nodes, Counts, ascending) ->
    lists:sort(fun(A, B) -> {maps:get(A, Counts), A} =<
                             {maps:get(B, Counts), B} end, Nodes);
nodes_by_load(Nodes, Counts, descending) ->
    lists:sort(fun(A, B) -> {maps:get(A, Counts), A} >=
                             {maps:get(B, Counts), B} end, Nodes).
