-module(erlite_placement).

%% Pure placement policy.  Metrics are hints: absent or malformed observations
%% receive neutral defaults, while hard disk limits always fail closed.
-export([choose_initial/4, node_scores/4, leader_plan/3, leader_plan/4,
         effective_options/2, can_place/3]).

-define(DEFAULT_DISK_RESERVE, 1073741824).

choose_initial(DatabaseId, Databases, Nodes, Options)
  when is_binary(DatabaseId), is_list(Databases), is_list(Nodes), is_map(Options) ->
    Effective = effective_options(DatabaseId, Options),
    Size = database_size(Effective),
    %% The catalog can use distinct Ra servers on one Erlang node in local
    %% integration tests. Production catalog membership supplies unique nodes.
    Eligible = [N || N <- Nodes, disk_ok(N, Size, Effective)],
    case length(Eligible) >= 3 of
        false -> {error, insufficient_placement_capacity};
        true ->
            Scores = node_scores(Databases, Eligible, Effective, Size),
            {ok, lists:sublist([N || {_Score, N} <- Scores], 3)}
    end.

node_scores(Databases, Nodes, Options, Size) ->
    Counts = replica_counts(Databases, Nodes),
    Metrics = maps:get(node_metrics, Options, #{}),
    Group = maps:get(placement_group, Options, undefined),
    Strategy = maps:get(placement_strategy, Options, spread),
    GroupCounts = group_counts(Databases, Nodes, Group, Options),
    lists:sort([{capacity_score(N, Counts, GroupCounts, Metrics, Strategy,
                                Size, Options), N}
                || N <- Nodes]).

capacity_score(Node, Counts, GroupCounts, Metrics, Strategy, Size, Options) ->
    case disk_ok(Node, Size, Options) of
        true -> score(Node, Counts, GroupCounts, Metrics, Strategy, Size);
        false -> 1000000000000000
    end.

score(Node, Counts, GroupCounts, Metrics, Strategy, Size) ->
    M = maps:get(Node, Metrics, #{}),
    ReplicaCost = maps:get(Node, Counts, 0) * 1000000,
    LoadCost = trunc(number(maps:get(load, M, 0)) * 100000),
    Used = maps:get(used_bytes, M, 0),
    Capacity = max(1, maps:get(capacity_bytes, M, max(1, Used + Size + 1))),
    DiskCost = trunc((Used + Size) * 100000 / Capacity),
    G = maps:get(Node, GroupCounts, 0),
    GroupCost = case Strategy of
        pack -> case G of 0 -> 2000000; _ -> -G * 10000 end;
        spread -> G * 2000000;
        _ -> G * 2000000
    end,
    ReplicaCost + LoadCost + DiskCost + GroupCost.

disk_ok(Node, Size, Options) ->
    Metrics = maps:get(node_metrics, Options, #{}),
    M = maps:get(Node, Metrics, #{}),
    case maps:find(free_bytes, M) of
        error -> true;
        {ok, Free} when is_integer(Free), Free >= 0 ->
            Reserve = maps:get(disk_reserve_bytes, Options,
                               ?DEFAULT_DISK_RESERVE),
            Free - Size >= Reserve;
        _ -> false
    end.

can_place(DatabaseId, Node, Options)
  when is_binary(DatabaseId), is_atom(Node), is_map(Options) ->
    Effective = effective_options(DatabaseId, Options),
    disk_ok(Node, database_size(Effective), Effective).

effective_options(DatabaseId, Options)
  when is_binary(DatabaseId), is_map(Options) ->
    PerDatabase = maps:get(databases, Options, #{}),
    Global = maps:remove(databases, Options),
    Override = maps:get(DatabaseId, PerDatabase, #{}),
    Merged = maps:merge(Global, Override),
    GlobalMetrics = maps:get(node_metrics, Global, #{}),
    OverrideMetrics = maps:get(node_metrics, Override, #{}),
    Merged#{node_metrics => maps:merge(GlobalMetrics, OverrideMetrics),
            databases => PerDatabase}.

database_size(Options) ->
    maps:get(size_bytes, Options,
             maps:get(default_database_size_bytes, Options, 0)).

leader_plan(Databases, CurrentLeaders, Limit)
  when is_list(Databases), is_map(CurrentLeaders),
       is_integer(Limit), Limit >= 0 ->
    Nodes = lists:usort([Node || #{replicas := Replicas} <- Databases,
                                {_, Node} <- Replicas]),
    leader_plan(Databases, CurrentLeaders, Nodes, Limit).

leader_plan(Databases, CurrentLeaders, EligibleNodes, Limit)
  when is_list(Databases), is_map(CurrentLeaders), is_list(EligibleNodes),
       is_integer(Limit), Limit >= 0 ->
    Counts0 = lists:foldl(fun({_Db, {_Name, Node}}, A) ->
                                  A#{Node => maps:get(Node, A, 0) + 1}
                          end, #{}, maps:to_list(CurrentLeaders)),
    leader_loop(lists:sort(Databases), CurrentLeaders, Counts0,
                EligibleNodes, Limit, []).

leader_loop(_, _, _, _, 0, Acc) -> lists:reverse(Acc);
leader_loop([], _, _, _, _, Acc) -> lists:reverse(Acc);
leader_loop([#{database_id := Id, replicas := Replicas} | Rest], Leaders,
            Counts, EligibleNodes, Limit, Acc) ->
    case maps:find(Id, Leaders) of
        {ok, Leader = {_, LeaderNode}} ->
            Targets = lists:sort(fun({_, A}, {_, B}) ->
                                         {maps:get(A, Counts, 0), A} =<
                                         {maps:get(B, Counts, 0), B}
                                 end,
                                 [R || R = {_, Node} <- Replicas,
                                       lists:member(Node, EligibleNodes)]),
            case Targets of
                [Target = {_, TargetNode} | _]
                  when TargetNode =/= LeaderNode ->
                    Difference = maps:get(LeaderNode, Counts, 0) -
                                 maps:get(TargetNode, Counts, 0),
                    case Difference > 1 of
                        true -> leader_loop(Rest, Leaders,
                                  Counts#{LeaderNode => maps:get(LeaderNode, Counts) - 1,
                                          TargetNode => maps:get(TargetNode, Counts, 0) + 1},
                                  EligibleNodes, Limit - 1,
                                  [{Id, Leader, Target} | Acc]);
                        false -> leader_loop(Rest, Leaders, Counts,
                                             EligibleNodes, Limit, Acc)
                    end;
                _ -> leader_loop(Rest, Leaders, Counts, EligibleNodes,
                                 Limit, Acc)
            end;
        error -> leader_loop(Rest, Leaders, Counts, EligibleNodes, Limit, Acc)
    end;
leader_loop([_ | Rest], Leaders, Counts, EligibleNodes, Limit, Acc) ->
    leader_loop(Rest, Leaders, Counts, EligibleNodes, Limit, Acc).

replica_counts(Databases, Nodes) ->
    Empty = maps:from_list([{N, 0} || N <- Nodes]),
    lists:foldl(fun(#{state := ready} = Database, A) ->
                        Rs = placement_replicas(Database),
                        lists:foldl(fun({_, N}, B) when is_map_key(N, B) ->
                                            B#{N => maps:get(N, B) + 1};
                                       (_, B) -> B
                                    end, A, Rs);
                   (_, A) -> A
                end, Empty, Databases).

placement_replicas(#{replicas := Replicas, movement :=
                          #{replacement := Replacement}}) ->
    lists:usort([Replacement | Replicas]);
placement_replicas(#{replicas := Replicas}) -> Replicas.

group_counts(_Databases, Nodes, undefined, _Options) ->
    maps:from_list([{N, 0} || N <- Nodes]);
group_counts(Databases, Nodes, Group, Options) ->
    Configured = maps:get(databases, Options, #{}),
    replica_counts([D || D <- Databases,
                         database_group(D, Configured) =:= Group], Nodes).

database_group(D, Configured) ->
    case maps:get(placement_group, D, undefined) of
        undefined ->
            Id = maps:get(database_id, D, undefined),
            maps:get(placement_group, maps:get(Id, Configured, #{}), undefined);
        Group -> Group
    end.

number(N) when is_integer(N); is_float(N) -> N;
number(_) -> 0.
