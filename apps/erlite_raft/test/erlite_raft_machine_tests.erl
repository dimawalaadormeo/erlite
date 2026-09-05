-module(erlite_raft_machine_tests).

-include_lib("eunit/include/eunit.hrl").

committed_commands_are_retained_in_raft_order_test() ->
    Command1 = command(<<"tx-1">>, 1),
    Command2 = command(<<"tx-2">>, 2),
    State0 = erlite_raft_machine:init(#{}),
    {State1, {committed, 2}, [{release_cursor, 2, State1}]} =
        erlite_raft_machine:apply(#{index => 2, term => 1}, Command1, State0),
    {State2, {committed, 5}, [{release_cursor, 5, State2}]} =
        erlite_raft_machine:apply(#{index => 5, term => 2}, Command2, State1),
    ?assertEqual([{2, 1, Command1}, {5, 2, Command2}],
                 erlite_raft_machine:entries_after(State2, 0)),
    ?assertEqual([{5, 2, Command2}],
                 erlite_raft_machine:entries_after(State2, 2)),
    ?assertEqual(5, erlite_raft_machine:last_index(State2)).

invalid_command_does_not_change_machine_state_test() ->
    State = erlite_raft_machine:init(#{}),
    ?assertEqual({State, {error, {invalid_command, invalid}}},
                 erlite_raft_machine:apply(
                   #{index => 1, term => 1}, invalid, State)).

command(TransactionId, Id) ->
    {ok, Command} = erlite_raft_command:new_transaction(
                      TransactionId, 0,
                      [{<<"INSERT INTO items (id) VALUES (?)">>, [Id]}]),
    Command.
