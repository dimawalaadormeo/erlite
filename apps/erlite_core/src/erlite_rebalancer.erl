-module(erlite_rebalancer).
-behaviour(gen_server).

-export([start_link/0, configure/2, scan/0, plan/3, plan/4]).
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
            Options = application:get_env(erlite_core, placement_options, #{}),
            case execute(plan(Databases, Nodes, Limit, Options), []) of
                ok -> refresh_and_balance_leaders(Catalog, Limit);
                Error -> Error
            end;
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

refresh_and_balance_leaders(Catalog, Limit) ->
    case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
        {ok, #{nodes := NodeRecords, databases := Databases}} ->
            HealthyNodes = [Node || #{state := active,
                                      server_id := {_, Node}} <- NodeRecords,
                                    node_healthy(Node)],
            balance_leaders(Databases, HealthyNodes, Limit);
        Error -> Error
    end.

balance_leaders(Databases, HealthyNodes, Limit) ->
    Eligible = [D || D = #{state := ready} <- Databases,
                     not maps:is_key(movement, D),
                     not maps:is_key(repair, D)],
    Leaders = lists:foldl(
      fun(#{database_id := Id, replicas := Replicas}, Acc) ->
              case ra:members(Replicas, ?TIMEOUT) of
                  {ok, Members, Leader} ->
                      case lists:member(Leader, Members) of
                          true -> Acc#{Id => Leader};
                          false -> Acc
                      end;
                  _ -> Acc
              end
      end, #{}, Eligible),
    execute_leader_plan(erlite_placement:leader_plan(
                          Eligible, Leaders, HealthyNodes, Limit), []).

execute_leader_plan([], []) -> ok;
execute_leader_plan([], Errors) ->
    {error, {leader_balance_failed, lists:reverse(Errors)}};
execute_leader_plan([{Id, Leader, Target} | Rest], Errors) ->
    case ra:transfer_leadership(Leader, Target, ?TIMEOUT) of
        ok -> execute_leader_plan(Rest, Errors);
        already_leader -> execute_leader_plan(Rest, Errors);
        Error -> execute_leader_plan(Rest, [{Id, Error} | Errors])
    end.

-spec plan([map()], [node()], non_neg_integer()) ->
    [{binary(), term(), node()}].
plan(Databases, ActiveNodes, Limit)
  when is_list(Databases), is_list(ActiveNodes),
       is_integer(Limit), Limit >= 0 ->
    plan(Databases, ActiveNodes, Limit, #{}).

plan(Databases, ActiveNodes, Limit, Options)
  when is_list(Databases), is_list(ActiveNodes),
       is_integer(Limit), Limit >= 0, is_map(Options) ->
    Stable = lists:sort(
               fun(A, B) -> maps:get(database_id, A) =<
                                maps:get(database_id, B) end,
               [D || D = #{state := ready, replicas := Replicas} <- Databases,
                     not maps:is_key(movement, D),
                     not maps:is_key(repair, D),
                     replicas_on_active_nodes(Replicas, ActiveNodes)]),
    plan_loop(Stable, Databases, replica_counts(Databases, ActiveNodes),
              ActiveNodes, Limit, [], Options).

plan_loop(_Candidates, _Inventory, _Counts, _Nodes, 0, Acc, _Options) ->
    lists:reverse(Acc);
plan_loop(Candidates, Inventory, Counts, Nodes, Remaining, Acc, Options) ->
    case choose_move(Candidates, Inventory, Counts, Nodes, Options) of
        none -> lists:reverse(Acc);
        {Database, Source, Target} ->
            DatabaseId = maps:get(database_id, Database),
            SourceNode = element(2, Source),
            Updated = Counts#{SourceNode => maps:get(SourceNode, Counts) - 1,
                              Target => maps:get(Target, Counts) + 1},
            Projected = project_move(Database, Source, Target, Inventory),
            plan_loop(lists:delete(Database, Candidates), Projected, Updated,
                      Nodes, Remaining - 1,
                      [{DatabaseId, Source, Target} | Acc], Options)
    end.

choose_move(Candidates, Inventory, Counts, Nodes, Options) ->
    EstimatedSize = maps:get(default_database_size_bytes, Options, 0),
    Ranked = erlite_placement:node_scores(Inventory, Nodes, Options,
                                          EstimatedSize),
    Targets = [N || {_, N} <- Ranked],
    Sources = lists:reverse(Targets),
    choose_source(Sources, Targets, Candidates, Counts, Options).

project_move(Database, Source, Target, Inventory) ->
    Replicas = maps:get(replicas, Database),
    Replacement = {projected_replacement, Target},
    Updated = Database#{replicas => [Replacement | lists:delete(Source, Replicas)]},
    [case maps:get(database_id, D) =:= maps:get(database_id, Database) of
         true -> Updated;
         false -> D
     end || D <- Inventory].

choose_source([], _Targets, _Databases, _Counts, _Options) -> none;
choose_source([SourceNode | Sources], Targets, Databases, Counts, Options) ->
    case choose_target(SourceNode, Targets, Databases, Counts, Options) of
        none -> choose_source(Sources, Targets, Databases, Counts, Options);
        Move -> Move
    end.

choose_target(_SourceNode, [], _Databases, _Counts, _Options) -> none;
choose_target(SourceNode, [Target | Targets], Databases, Counts, Options) ->
    case maps:get(SourceNode, Counts) - maps:get(Target, Counts) > 1 of
        false -> choose_target(SourceNode, Targets, Databases, Counts, Options);
        true ->
            case database_for_move(Databases, SourceNode, Target, Options) of
                none -> choose_target(SourceNode, Targets, Databases, Counts,
                                      Options);
                {Database, Source} -> {Database, Source, Target}
            end
    end.

database_for_move([], _SourceNode, _Target, _Options) -> none;
database_for_move([Database = #{replicas := Replicas} | Rest], SourceNode,
                  Target, Options) ->
    DatabaseId = maps:get(database_id, Database),
    case {server_on_node(Replicas, SourceNode), server_on_node(Replicas, Target),
          erlite_placement:can_place(DatabaseId, Target, Options)} of
        {{ok, Source}, error, true} -> {Database, Source};
        _ -> database_for_move(Rest, SourceNode, Target, Options)
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
      fun(#{state := ready, replicas := Replicas} = Database, Counts) ->
              EffectiveReplicas = case maps:find(movement, Database) of
                  {ok, #{replacement := Replacement}} ->
                      lists:usort([Replacement | Replicas]);
                  _ -> Replicas
              end,
              lists:foldl(
                fun({_, Node}, Inner) ->
                        case maps:is_key(Node, Inner) of
                            true -> Inner#{Node => maps:get(Node, Inner) + 1};
                            false -> Inner
                        end
                end, Counts, EffectiveReplicas);
         (_, Counts) -> Counts
      end, Empty, Databases).
