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

database_lifecycle_is_idempotent_and_generation_fenced_test() ->
    State0 = catalog_state(),
    DatabaseId = <<"merchant-1">>,
    CreateOp = <<1:128>>,
    DeleteOp = <<2:128>>,
    Replicas = database_replicas(one),
    Create = {prepare_database_create, DatabaseId, CreateOp, 1, Replicas},
    {State1, ok} = erlite_catalog_machine:apply(#{index => 1}, Create, State0),
    ReorderedCreate = {prepare_database_create, DatabaseId, CreateOp, 1,
                       lists:reverse(Replicas)},
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 2}, ReorderedCreate, State1),
    {ok, #{state := creating, generation := 1}} =
        erlite_catalog_machine:database(DatabaseId, State1),
    [#{database_id := DatabaseId}] = erlite_catalog_machine:recoverable(State1),
    {State2, ok} = erlite_catalog_machine:apply(
                     #{index => 3},
                     {mark_database_ready, DatabaseId, CreateOp, 1}, State1),
    [] = erlite_catalog_machine:recoverable(State2),
    {State2, {error, {stale_generation, 2, 1}}} =
        erlite_catalog_machine:apply(
          #{index => 4},
          {prepare_database_delete, DatabaseId, <<9:128>>, 2}, State2),
    {State3, ok} = erlite_catalog_machine:apply(
                     #{index => 5},
                     {prepare_database_delete, DatabaseId, DeleteOp, 1}, State2),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 6},
                     {tombstone_database, DatabaseId, DeleteOp, 1}, State3),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 7},
                     {tombstone_database, DatabaseId, DeleteOp, 1}, State4),
    RecreateOp = <<3:128>>,
    {State5, ok} = erlite_catalog_machine:apply(
                     #{index => 8},
                     {prepare_database_create, DatabaseId, RecreateOp, 2,
                      database_replicas(two)}, State4),
    {ok, #{state := creating, generation := 2,
           operation_id := RecreateOp}} =
        erlite_catalog_machine:database(DatabaseId, State5).

stale_database_operations_fail_closed_test() ->
    State0 = catalog_state(),
    DatabaseId = <<"merchant-2">>,
    OperationId = <<4:128>>,
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 1},
                     {prepare_database_create, DatabaseId, OperationId, 1,
                      database_replicas(one)}, State0),
    {State1, {error, {operation_id_conflict, OperationId}}} =
        erlite_catalog_machine:apply(
          #{index => 2},
          {mark_database_ready, DatabaseId, <<5:128>>, 1}, State1),
    {State1, {error, {invalid_lifecycle_transition, creating, deleting}}} =
        erlite_catalog_machine:apply(
          #{index => 3},
          {prepare_database_delete, DatabaseId, <<7:128>>, 1}, State1),
    {State1, {error, {stale_generation, 2, 1}}} =
        erlite_catalog_machine:apply(
          #{index => 4},
          {mark_database_ready, DatabaseId, OperationId, 2}, State1),
    {State1, {error, {operation_id_conflict, OperationId}}} =
        erlite_catalog_machine:apply(
          #{index => 5},
          {prepare_database_create, DatabaseId, <<6:128>>, 1,
           database_replicas(one)}, State1).

database_move_is_durable_idempotent_and_ordered_test() ->
    DatabaseId = <<"merchant-move">>,
    Replicas = database_replicas(one),
    Source = hd(Replicas),
    Replacement = {database_replacement, node()},
    State0 = ready_database(DatabaseId, <<8:128>>, Replicas),
    Prepare = {prepare_database_move, DatabaseId, <<9:128>>, 1, Source,
               Replacement},
    {State1, ok} = erlite_catalog_machine:apply(#{index => 3}, Prepare, State0),
    {State1, ok} = erlite_catalog_machine:apply(#{index => 4}, Prepare, State1),
    {ok, #{state := ready, replicas := Replicas,
           movement := #{phase := adding}}} =
        erlite_catalog_machine:database(DatabaseId, State1),
    [#{database_id := DatabaseId}] = erlite_catalog_machine:recoverable(State1),
    {State1, {error, {invalid_movement_transition, adding}}} =
        erlite_catalog_machine:apply(
          #{index => 5}, {finish_database_move, DatabaseId, <<9:128>>, 1}, State1),
    Ready = {mark_database_replacement_ready, DatabaseId, <<9:128>>, 1},
    {State2, ok} = erlite_catalog_machine:apply(#{index => 6}, Ready, State1),
    {State2, ok} = erlite_catalog_machine:apply(#{index => 7}, Ready, State2),
    Finish = {finish_database_move, DatabaseId, <<9:128>>, 1},
    {State3, ok} = erlite_catalog_machine:apply(#{index => 8}, Finish, State2),
    {State3, ok} = erlite_catalog_machine:apply(#{index => 9}, Finish, State3),
    {ok, Final} = erlite_catalog_machine:database(DatabaseId, State3),
    2 = maps:get(generation, Final),
    false = maps:is_key(movement, Final),
    false = lists:member(Source, maps:get(replicas, Final)),
    true = lists:member(Replacement, maps:get(replicas, Final)),
    [] = erlite_catalog_machine:recoverable(State3).

delete_is_fenced_while_database_move_is_in_progress_test() ->
    DatabaseId = <<"merchant-moving-delete">>,
    Replicas = database_replicas(one),
    State0 = ready_database(DatabaseId, <<12:128>>, Replicas),
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 3},
                     {prepare_database_move, DatabaseId, <<13:128>>, 1,
                      hd(Replicas), {replacement, node()}}, State0),
    {State1, {error, {movement_in_progress, <<13:128>>}}} =
        erlite_catalog_machine:apply(
          #{index => 4},
          {prepare_database_delete, DatabaseId, <<14:128>>, 1}, State1).

database_move_rejects_unsafe_replacement_test() ->
    DatabaseId = <<"merchant-move-fences">>,
    Replicas = database_replicas(one),
    State = ready_database(DatabaseId, <<10:128>>, Replicas),
    {State, {error, source_not_in_placement}} = erlite_catalog_machine:apply(
      #{index => 3},
      {prepare_database_move, DatabaseId, <<11:128>>, 1,
       {missing, node()}, {replacement, node()}}, State),
    {State, {error, replacement_already_in_placement}} =
        erlite_catalog_machine:apply(
          #{index => 4},
          {prepare_database_move, DatabaseId, <<11:128>>, 1, hd(Replicas),
           lists:last(Replicas)}, State),
    {State, {error, replacement_unavailable}} =
        erlite_catalog_machine:apply(
          #{index => 5},
          {prepare_database_move, DatabaseId, <<11:128>>, 1, hd(Replicas),
           {replacement, 'not-active@host'}}, State).

ready_database(DatabaseId, OperationId, Replicas) ->
    State0 = catalog_state(),
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 1},
                     {prepare_database_create, DatabaseId, OperationId, 1,
                      Replicas}, State0),
    {State2, ok} = erlite_catalog_machine:apply(
                     #{index => 2},
                     {mark_database_ready, DatabaseId, OperationId, 1}, State1),
    State2.

catalog_state() ->
    erlite_catalog_machine:init(
      #{cluster_id => <<0:128>>, cluster_name => <<"test">>,
        nodes => catalog_nodes()}).

database_replicas(Prefix) ->
    [{list_to_atom("database_" ++ atom_to_list(Prefix) ++ integer_to_list(N)),
      node()} || N <- [1, 2, 3]].

catalog_nodes() ->
    [#{node_id => <<N:128>>, node_name => integer_to_binary(N),
       server_id => {list_to_atom("catalog_" ++ integer_to_list(N)), node()}}
     || N <- [1, 2, 3]].
