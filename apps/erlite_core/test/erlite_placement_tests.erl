-module(erlite_placement_tests).
-include_lib("eunit/include/eunit.hrl").

size_disk_and_load_aware_initial_placement_test() ->
    Nodes = [a@h,b@h,c@h,d@h],
    Metrics = #{a@h => #{free_bytes => 50, capacity_bytes => 100, used_bytes => 50},
                b@h => #{free_bytes => 900, capacity_bytes => 1000, used_bytes => 100},
                c@h => #{free_bytes => 800, capacity_bytes => 1000, used_bytes => 200},
                d@h => #{free_bytes => 700, capacity_bytes => 1000,
                          used_bytes => 300, load => 20}},
    {ok, Chosen} = erlite_placement:choose_initial(
                     <<"new">>, [], Nodes,
                     #{size_bytes => 100, disk_reserve_bytes => 10,
                       node_metrics => Metrics}),
    ?assertEqual([b@h,c@h,d@h], Chosen),
    ?assertNot(lists:member(a@h, Chosen)).

default_size_is_used_for_initial_disk_admission_test() ->
    Nodes = [a@h,b@h,c@h,d@h],
    Metrics = #{a@h => #{free_bytes => 109},
                b@h => #{free_bytes => 200},
                c@h => #{free_bytes => 200},
                d@h => #{free_bytes => 200}},
    {ok, Chosen} = erlite_placement:choose_initial(
                     <<"new">>, [], Nodes,
                     #{default_database_size_bytes => 100,
                       disk_reserve_bytes => 10, node_metrics => Metrics}),
    ?assertNot(lists:member(a@h, Chosen)).

per_database_metrics_are_deep_merged_test() ->
    Options = #{node_metrics => #{a@h => #{free_bytes => 100},
                                  b@h => #{free_bytes => 200}},
                databases => #{<<"db">> =>
                                   #{node_metrics =>
                                         #{a@h => #{free_bytes => 50}}}}},
    Effective = erlite_placement:effective_options(<<"db">>, Options),
    ?assertEqual(#{a@h => #{free_bytes => 50},
                   b@h => #{free_bytes => 200}},
                 maps:get(node_metrics, Effective)).

placement_group_spread_and_pack_test() ->
    A=a@h, B=b@h, C=c@h, D=d@h,
    Existing = [#{database_id => <<"old">>, state => ready,
                  placement_group => <<"g">>,
                  replicas => [s(a,A),s(b,B),s(c,C)]}],
    {ok, Spread} = erlite_placement:choose_initial(
                     <<"new">>, Existing, [A,B,C,D],
                     #{placement_group => <<"g">>, placement_strategy => spread,
                       disk_reserve_bytes => 0}),
    ?assertEqual(D, hd(Spread)),
    {ok, Pack} = erlite_placement:choose_initial(
                   <<"new">>, Existing, [A,B,C,D],
                   #{placement_group => <<"g">>, placement_strategy => pack,
                     disk_reserve_bytes => 0}),
    ?assertNot(lists:member(D, Pack)).

leader_balancing_is_bounded_test() ->
    A=a@h, B=b@h, C=c@h,
    Dbs = [db(<<"1">>, A,B,C), db(<<"2">>, A,B,C), db(<<"3">>, A,B,C)],
    Leaders = #{<<"1">> => s(a1,A), <<"2">> => s(a2,A), <<"3">> => s(a3,A)},
    Plan = erlite_placement:leader_plan(Dbs, Leaders, 2),
    ?assertEqual(2, length(Plan)),
    ?assert(lists:all(fun({_Id,_From,{_,N}}) -> N =/= A end, Plan)).

leader_balancing_excludes_unhealthy_targets_test() ->
    A=a@h, B=b@h, C=c@h,
    Dbs = [db(<<"1">>, A,B,C), db(<<"2">>, A,B,C), db(<<"3">>, A,B,C)],
    Leaders = #{<<"1">> => s(a1,A), <<"2">> => s(a2,A), <<"3">> => s(a3,A)},
    Plan = erlite_placement:leader_plan(Dbs, Leaders, [A,C], 2),
    ?assert(lists:all(fun({_Id,_From,{_,N}}) -> N =:= C end, Plan)).

inflight_replacement_is_counted_in_node_score_test() ->
    Moving = #{database_id => <<"moving">>, state => ready,
               replicas => [s(a,a@h),s(b,b@h),s(c,c@h)],
               movement => #{replacement => s(d,d@h)}},
    Scores = erlite_placement:node_scores(
               [Moving], [a@h,b@h,c@h,d@h], #{}, 0),
    ?assertEqual([{1000000,a@h},{1000000,b@h},{1000000,c@h},{1000000,d@h}],
                 Scores).

db(Id,A,B,C) -> #{database_id => Id, state => ready,
                  replicas => [s(binary_to_atom(<<Id/binary,"a">>),A),
                               s(binary_to_atom(<<Id/binary,"b">>),B),
                               s(binary_to_atom(<<Id/binary,"c">>),C)]}.
s(Name, Node) -> {Name, Node}.
