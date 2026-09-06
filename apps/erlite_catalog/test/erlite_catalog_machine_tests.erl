-module(erlite_catalog_machine_tests).

-include_lib("eunit/include/eunit.hrl").

catalog_initializes_rf_three_and_quorum_two_test() ->
    Nodes = catalog_nodes(),
    State = erlite_catalog_machine:init(
              #{cluster_id => <<0:128>>, cluster_name => <<"test">>,
                nodes => Nodes}),
    Status = erlite_catalog_machine:status(State),
    ?assertEqual(3, maps:get(replication_factor, Status)),
    ?assertEqual(2, maps:get(quorum, Status)),
    ?assertEqual(3, length(maps:get(nodes, Status))).

unsupported_command_does_not_change_catalog_test() ->
    State = erlite_catalog_machine:init(
              #{cluster_id => <<0:128>>, cluster_name => <<"test">>,
                nodes => catalog_nodes()}),
    ?assertEqual({State, {error, {unsupported_catalog_command, unsafe}}},
                 erlite_catalog_machine:apply(#{index => 1}, unsafe, State)).

join_and_leave_are_idempotent_state_transitions_test() ->
    State0 = erlite_catalog_machine:init(
               #{cluster_id => <<0:128>>, cluster_name => <<"test">>,
                 nodes => catalog_nodes()}),
    Joining = #{node_id => <<4:128>>, node_name => <<"4">>,
                server_id => {catalog_4, node()}},
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 1}, {prepare_join, Joining}, State0),
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 2}, {prepare_join, Joining}, State1),
    {State2, ok} = erlite_catalog_machine:apply(
                     #{index => 3}, {activate_node, <<4:128>>}, State1),
    {State3, ok} = erlite_catalog_machine:apply(
                     #{index => 4}, {prepare_leave, <<4:128>>}, State2),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 5}, {finalize_leave, <<4:128>>}, State3),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 6}, {finalize_leave, <<4:128>>}, State4),
    ?assertEqual(3, length(maps:get(nodes,
                                    erlite_catalog_machine:status(State4)))).

identity_collisions_are_rejected_test() ->
    State = erlite_catalog_machine:init(
              #{cluster_id => <<0:128>>, cluster_name => <<"test">>,
                nodes => catalog_nodes()}),
    DuplicateName = #{node_id => <<4:128>>, node_name => <<"1">>,
                      server_id => {catalog_4, node()}},
    ?assertMatch({State, {error, duplicate_node_name}},
                 erlite_catalog_machine:apply(
                   #{index => 1}, {prepare_join, DuplicateName}, State)).

catalog_nodes() ->
    [#{node_id => <<N:128>>, node_name => integer_to_binary(N),
       server_id => {list_to_atom("catalog_" ++ integer_to_list(N)), node()}}
     || N <- [1, 2, 3]].
