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

database_repair_is_durable_serialized_and_tracks_stale_replica_test() ->
    DatabaseId = <<"merchant-repair">>,
    Replicas = database_replicas(one),
    Failed = hd(Replicas),
    Replacement = {repair_replacement, node()},
    OperationId = <<15:128>>,
    State0 = ready_database(DatabaseId, <<14:128>>, Replicas),
    Mark = {mark_database_under_replicated, DatabaseId, OperationId, 1,
            Failed, 1000},
    {State1, ok} = erlite_catalog_machine:apply(#{index => 3}, Mark, State0),
    {State1, ok} = erlite_catalog_machine:apply(#{index => 4}, Mark, State1),
    {ok, #{repair := #{phase := waiting, detected_at := 1000}}} =
        erlite_catalog_machine:database(DatabaseId, State1),
    {State1, {error, {repair_in_progress, OperationId}}} =
        erlite_catalog_machine:apply(
          #{index => 5},
          {prepare_database_move, DatabaseId, <<16:128>>, 1, Failed,
           Replacement}, State1),
    {State1, {error, {repair_in_progress, OperationId}}} =
        erlite_catalog_machine:apply(
          #{index => 5},
          {prepare_database_delete, DatabaseId, <<19:128>>, 1}, State1),
    Prepare = {prepare_database_repair, DatabaseId, OperationId, 1, Failed,
               Replacement},
    {State2, ok} = erlite_catalog_machine:apply(#{index => 6}, Prepare, State1),
    {State2, ok} = erlite_catalog_machine:apply(#{index => 7}, Prepare, State2),
    {ok, #{repair := #{phase := repairing},
           movement := #{phase := adding, kind := repair}}} =
        erlite_catalog_machine:database(DatabaseId, State2),
    {State3, ok} = erlite_catalog_machine:apply(
                     #{index => 8},
                     {mark_database_replacement_ready, DatabaseId,
                      OperationId, 1}, State2),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 9},
                     {finish_database_move, DatabaseId, OperationId, 1},
                     State3),
    {ok, #{generation := 2, stale_replicas := [Stale]} = Final} =
        erlite_catalog_machine:database(DatabaseId, State4),
    false = maps:is_key(repair, Final),
    false = maps:is_key(movement, Final),
    Failed = maps:get(server_id, Stale),
    {State5, ok} = erlite_catalog_machine:apply(
                     #{index => 10},
                     {clear_stale_replica, DatabaseId, Failed, 1, 2}, State4),
    {ok, Clean} = erlite_catalog_machine:database(DatabaseId, State5),
    false = maps:is_key(stale_replicas, Clean).

transient_under_replication_can_be_cleared_before_repair_test() ->
    DatabaseId = <<"merchant-transient-failure">>,
    Replicas = database_replicas(one),
    OperationId = <<17:128>>,
    State0 = ready_database(DatabaseId, <<18:128>>, Replicas),
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 3},
                     {mark_database_under_replicated, DatabaseId, OperationId,
                      1, hd(Replicas), 2000}, State0),
    {State2, ok} = erlite_catalog_machine:apply(
                     #{index => 4},
                     {clear_database_under_replicated, DatabaseId,
                      OperationId, 1}, State1),
    {ok, Database} = erlite_catalog_machine:database(DatabaseId, State2),
    false = maps:is_key(repair, Database).

restore_and_clone_are_durable_idempotent_and_generation_fenced_test() ->
    ReplaceId = <<"replace-target">>,
    Backup = backup_descriptor(ReplaceId),
    OldReplicas = database_replicas(one),
    NewReplicas = database_replicas(two),
    State0 = ready_database(ReplaceId, <<20:128>>, OldReplicas),
    ReplaceOp = <<21:128>>,
    Replace = {prepare_database_restore, ReplaceId, ReplaceOp, 1, 2,
               NewReplicas, Backup, replace},
    {State1, ok} = erlite_catalog_machine:apply(#{index => 3}, Replace, State0),
    {State1, ok} = erlite_catalog_machine:apply(#{index => 4}, Replace, State1),
    {ok, #{state := restoring, generation := 2,
           restore := #{previous_replicas := OldReplicas}}} =
        erlite_catalog_machine:database(ReplaceId, State1),
    [_] = erlite_catalog_machine:recoverable(State1),
    {State1, {error, {stale_generation, 1, 2}}} =
        erlite_catalog_machine:apply(
          #{index => 5},
          {finish_database_restore, ReplaceId, ReplaceOp, 1}, State1),
    Finish = {finish_database_restore, ReplaceId, ReplaceOp, 2},
    {State2, ok} = erlite_catalog_machine:apply(#{index => 6}, Finish, State1),
    {State2, ok} = erlite_catalog_machine:apply(#{index => 7}, Finish, State2),
    {ok, Ready} = erlite_catalog_machine:database(ReplaceId, State2),
    ready = maps:get(state, Ready),
    false = maps:is_key(restore, Ready),

    CloneId = <<"clone-target">>,
    CloneOp = <<22:128>>,
    Clone = {prepare_database_restore, CloneId, CloneOp, 0, 1,
             database_replicas(three), Backup, clone},
    {State3, ok} = erlite_catalog_machine:apply(#{index => 8}, Clone, State2),
    {ok, #{state := restoring, generation := 1,
           restore := #{mode := clone}}} =
        erlite_catalog_machine:database(CloneId, State3).

replace_restore_rejects_a_different_database_backup_test() ->
    DatabaseId = <<"replace-identity-target">>,
    Replicas = database_replicas(one),
    State = ready_database(DatabaseId, <<23:128>>, Replicas),
    Command = {prepare_database_restore, DatabaseId, <<24:128>>, 1, 2,
               database_replicas(two),
               backup_descriptor(<<"different-database">>), replace},
    {State, {error, backup_database_mismatch}} =
        erlite_catalog_machine:apply(#{index => 3}, Command, State),
    {ok, #{state := ready, generation := 1, replicas := Replicas}} =
        erlite_catalog_machine:database(DatabaseId, State).

migration_campaign_is_durable_pauseable_and_reported_test() ->
    CampaignId = <<31:128>>,
    Campaign = #{campaign_id => CampaignId, migration_set => <<"app">>,
                 idempotency_key => <<"deploy-app-v1">>,
                 databases => [<<"a">>, <<"b">>],
                 migrations => [#{id => <<"one">>, from => 0, to => 1,
                                  statements => [{<<"CREATE TABLE x (id INTEGER)">>, []}]}],
                 canary_size => 1, batch_size => 10, max_retries => 1},
    State0 = catalog_state(),
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 1}, {create_migration_campaign, Campaign}, State0),
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 2}, {create_migration_campaign, Campaign}, State1),
    {State2, ok} = erlite_catalog_machine:apply(
                     #{index => 3}, {set_migration_campaign_state,
                                     CampaignId, paused}, State1),
    {ok, #{status := paused}} = erlite_catalog_machine:campaign(CampaignId, State2),
    {State3, ok} = erlite_catalog_machine:apply(
                     #{index => 4}, {set_migration_campaign_state,
                                     CampaignId, running}, State2),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 4}, {record_migration_result,
                     CampaignId, <<"a">>, 1, ok}, State3),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 5}, {record_migration_result,
                     CampaignId, <<"a">>, 1, ok}, State4),
    {State5, ok} = erlite_catalog_machine:apply(
                     #{index => 6}, {record_migration_result,
                     CampaignId, <<"b">>, 1, ok}, State4),
    {ok, #{status := complete, entries := Entries}} =
        erlite_catalog_machine:campaign(CampaignId, State5),
    complete = maps:get(status, maps:get(<<"a">>, Entries)).

paused_campaign_is_not_resumed_by_inflight_result_test() ->
    Id = <<32:128>>,
    Campaign = #{campaign_id => Id, migration_set => <<"app">>,
                 idempotency_key => <<"pause-race">>, databases => [<<"a">>],
                 migrations => [#{id => <<"one">>, from => 0, to => 1,
                                  statements => [{<<"CREATE TABLE x (id INTEGER)">>, []}]}],
                 canary_size => 1, batch_size => 1, max_retries => 1},
    {State1, ok} = erlite_catalog_machine:apply(
                     #{index => 1}, {create_migration_campaign, Campaign},
                     catalog_state()),
    {State2, ok} = erlite_catalog_machine:apply(
                     #{index => 2}, {set_migration_campaign_state, Id, paused},
                     State1),
    {State3, ok} = erlite_catalog_machine:apply(
                     #{index => 3}, {record_migration_result, Id, <<"a">>, 1, ok},
                     State2),
    {ok, #{status := paused}} = erlite_catalog_machine:campaign(Id, State3),
    {State4, ok} = erlite_catalog_machine:apply(
                     #{index => 4}, {set_migration_campaign_state, Id, running},
                     State3),
    {ok, #{status := complete}} = erlite_catalog_machine:campaign(Id, State4).

schema_advance_is_fenced_by_other_database_operations_test() ->
    Id = <<"migration-fence">>,
    State0 = ready_database(Id, <<33:128>>, database_replicas(one)),
    #{databases := Databases} = State0,
    Database = maps:get(Id, Databases),
    MoveOp = <<34:128>>,
    Moving = State0#{databases => Databases#{Id =>
                  Database#{movement => #{operation_id => MoveOp}}}},
    {Moving, {error, {movement_in_progress, MoveOp}}} =
        erlite_catalog_machine:apply(
          #{index => 3}, {advance_database_schema, Id, 1, 0, 1}, Moving),
    RepairOp = <<35:128>>,
    Repairing = State0#{databases => Databases#{Id =>
                    Database#{repair => #{operation_id => RepairOp}}}},
    {Repairing, {error, {repair_in_progress, RepairOp}}} =
        erlite_catalog_machine:apply(
          #{index => 3}, {advance_database_schema, Id, 1, 0, 1}, Repairing),
    Restoring = State0#{databases => Databases#{Id =>
                    Database#{state => restoring}}},
    {Restoring, {error, {database_not_ready, restoring}}} =
        erlite_catalog_machine:apply(
          #{index => 3}, {advance_database_schema, Id, 1, 0, 1}, Restoring).

database_migration_fence_serializes_and_finishes_idempotently_test() ->
    Id = <<"fenced-migration">>,
    Campaign = <<36:128>>,
    Migration = <<"create-table">>,
    State0 = ready_database(Id, <<37:128>>, database_replicas(one)),
    Prepare = {prepare_database_migration, Id, Campaign, Migration, 1, 0, 1},
    {State1, ok} = erlite_catalog_machine:apply(#{index => 3}, Prepare, State0),
    {State1, ok} = erlite_catalog_machine:apply(#{index => 4}, Prepare, State1),
    {ok, #{migration := #{campaign_id := Campaign}}} =
        erlite_catalog_machine:database(Id, State1),
    [Source | _] = database_replicas(one),
    Replacement = {migration_replacement, node()},
    {State1, {error, {migration_in_progress, Campaign}}} =
        erlite_catalog_machine:apply(
          #{index => 5},
          {prepare_database_move, Id, <<38:128>>, 1, Source, Replacement},
          State1),
    Finish = {finish_database_migration, Id, Campaign, Migration, 1, 0, 1},
    {State2, ok} = erlite_catalog_machine:apply(#{index => 6}, Finish, State1),
    {State2, ok} = erlite_catalog_machine:apply(#{index => 7}, Finish, State2),
    {ok, Ready} = erlite_catalog_machine:database(Id, State2),
    1 = maps:get(schema_version, Ready),
    false = maps:is_key(migration, Ready).

backup_descriptor(DatabaseId) ->
    #{database_id => DatabaseId, generation => 4, raft_index => 99,
      raft_term => 7, schema_version => 3, created_at => 1000,
      sha256 => <<0:256>>, manifest_path => "/backups/test.manifest",
      source_server => {database_one1, node()}}.

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
