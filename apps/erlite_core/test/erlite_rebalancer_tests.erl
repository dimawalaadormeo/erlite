-module(erlite_rebalancer_tests).
-include_lib("eunit/include/eunit.hrl").

plans_bounded_balancing_moves_test() ->
    A = a@host, B = b@host, C = c@host, D = d@host,
    Databases = [db(<<"1">>, [s(a1,A),s(b1,B),s(c1,C)]),
                 db(<<"2">>, [s(a2,A),s(b2,B),s(c2,C)]),
                 db(<<"3">>, [s(a3,A),s(b3,B),s(c3,C)]),
                 db(<<"4">>, [s(a4,A),s(b4,B),s(c4,C)])],
    Moves = erlite_rebalancer:plan(Databases, [A,B,C,D], 2),
    ?assertEqual(2, length(Moves)),
    ?assert(lists:all(fun({_Id,_Source,Target}) -> Target =:= D end, Moves)),
    ?assertEqual(2, length(lists:usort([Id || {Id,_,_} <- Moves]))).

balanced_placement_is_stable_test() ->
    A = a@host, B = b@host, C = c@host, D = d@host,
    Databases = [db(<<"1">>, [s(a1,A),s(b1,B),s(c1,C)]),
                 db(<<"2">>, [s(a2,A),s(b2,B),s(d2,D)]),
                 db(<<"3">>, [s(a3,A),s(c3,C),s(d3,D)]),
                 db(<<"4">>, [s(b4,B),s(c4,C),s(d4,D)])],
    ?assertEqual([], erlite_rebalancer:plan(Databases, [A,B,C,D], 3)).

skips_inflight_and_inactive_placements_test() ->
    A = a@host, B = b@host, C = c@host, D = d@host,
    Moving = (db(<<"1">>, [s(a1,A),s(b1,B),s(c1,C)]))#{movement => #{}},
    Repair = (db(<<"2">>, [s(a2,A),s(b2,B),s(c2,C)]))#{repair => #{}},
    Missing = db(<<"3">>, [s(a3,A),s(b3,B),s(x3,missing@host)]),
    ?assertEqual([], erlite_rebalancer:plan([Moving,Repair,Missing],
                                            [A,B,C,D], 3)).

disk_reserve_is_a_hard_rebalance_gate_test() ->
    A=a@host, B=b@host, C=c@host, D=d@host,
    Databases = [db(<<"1">>, [s(a1,A),s(b1,B),s(c1,C)]),
                 db(<<"2">>, [s(a2,A),s(b2,B),s(c2,C)]),
                 db(<<"3">>, [s(a3,A),s(b3,B),s(c3,C)])],
    Options = #{default_database_size_bytes => 100,
                disk_reserve_bytes => 10,
                node_metrics => #{D => #{free_bytes => 109}}},
    ?assertEqual([], erlite_rebalancer:plan(Databases, [A,B,C,D], 1,
                                             Options)).

composite_target_rejection_tries_later_candidates_test() ->
    A=a@host, B=b@host, C=c@host, D=d@host,
    Databases = [db(<<"1">>, [s(a1,A),s(b1,B),s(c1,C)]),
                 db(<<"2">>, [s(a2,A),s(b2,B),s(c2,C)]),
                 db(<<"3">>, [s(a3,A),s(b3,B),s(c3,C)]),
                 db(<<"4">>, [s(a4,A),s(b4,B),s(d4,D)])],
    %% B sorts ahead of D by composite score but cannot improve A's count.
    Options = #{node_metrics => #{D => #{load => 100}}},
    [{_Id, {_Name, Source}, D}] = erlite_rebalancer:plan(
                                     Databases, [A,B,C,D], 1, Options),
    ?assert(lists:member(Source, [A,B])).

db(Id, Replicas) -> #{database_id => Id, state => ready, replicas => Replicas}.
s(Name, Node) -> {Name, Node}.
