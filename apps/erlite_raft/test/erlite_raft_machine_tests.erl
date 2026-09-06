-module(erlite_raft_machine_tests).

-include_lib("eunit/include/eunit.hrl").

committed_commands_are_retained_in_raft_order_test() ->
    Command1 = command(<<"tx-1">>, 1),
    Command2 = command(<<"tx-2">>, 2),
    RuntimeIdentity = runtime_identity(),
    State0 = erlite_raft_machine:init(
               #{runtime_identity => RuntimeIdentity}),
    {State1, {committed, 2}, [{release_cursor, 2, State1}]} =
        erlite_raft_machine:apply(#{index => 2, term => 1}, Command1, State0),
    {State2, {committed, 5}, [{release_cursor, 5, State2}]} =
        erlite_raft_machine:apply(#{index => 5, term => 2}, Command2, State1),
    ?assertEqual([{2, 1, Command1}, {5, 2, Command2}],
                 erlite_raft_machine:entries_after(State2, 0)),
    ?assertEqual([{5, 2, Command2}],
                 erlite_raft_machine:entries_after(State2, 2)),
    ?assertEqual(5, erlite_raft_machine:last_index(State2)),
    ?assertEqual(#{raft_index => 8, term => 3, command_index => 5,
                   command_term => 2, checkpoint => none,
                   runtime_identity => RuntimeIdentity},
                 erlite_raft_machine:barrier(
                   #{index => 8, term => 3}, State2)).

invalid_command_does_not_change_machine_state_test() ->
    State = erlite_raft_machine:init(
              #{runtime_identity => runtime_identity()}),
    ?assertEqual({State, {error, {invalid_command, invalid}}},
                 erlite_raft_machine:apply(
                   #{index => 1, term => 1}, invalid, State)).

checkpoint_prunes_only_entries_covered_by_verified_manifests_test() ->
    State0 = erlite_raft_machine:init(
               #{runtime_identity => runtime_identity()}),
    {State1, _, _} = erlite_raft_machine:apply(
                       #{index => 2, term => 1}, command(<<"tx-1">>, 1), State0),
    {State2, _, _} = erlite_raft_machine:apply(
                       #{index => 4, term => 1}, command(<<"tx-2">>, 2), State1),
    Manifests = #{{replica, node()} => "/snapshots/at-two.manifest"},
    {State3, {checkpointed, 2}, [{release_cursor, 5, State3}]} =
        erlite_raft_machine:apply(
          #{index => 5, term => 1}, {checkpoint, 2, Manifests}, State2),
    ?assertEqual([{4, 1, command(<<"tx-2">>, 2)}],
                 erlite_raft_machine:entries_after(State3, 2)),
    ?assertEqual({snapshot_required, "/snapshots/at-two.manifest"},
                 erlite_raft_machine:recovery_after(
                   0, {replica, node()}, State3)),
    ?assertEqual({ok, [{4, 1, command(<<"tx-2">>, 2)}]},
                 erlite_raft_machine:recovery_after(
                   2, {replica, node()}, State3)).

command(TransactionId, Id) ->
    {ok, Command} = erlite_raft_command:new_transaction(
                      TransactionId, 0,
                      [{<<"INSERT INTO items (id) VALUES (?)">>, [Id]}]),
    Command.

runtime_identity() ->
    #{sqlite_version => <<"test">>, sqlite_source_id => <<"test-source">>,
      compile_options => []}.
