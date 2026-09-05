-module(erlite_raft_command_tests).

-include_lib("eunit/include/eunit.hrl").

transaction_command_round_trip_test() ->
    Mutations = [{<<"INSERT INTO items(id, name) VALUES (?, ?)">>,
                  [1, <<"first">>]},
                 {<<"UPDATE items SET name = ? WHERE id = ?">>,
                  [<<"updated">>, 1]}],
    {ok, Command} = erlite_raft_command:new_transaction(
                      <<"transaction-1">>, 3, Mutations),
    ?assertEqual(ok, erlite_raft_command:validate(Command)),
    ?assertEqual(<<"transaction-1">>,
                 erlite_raft_command:transaction_id(Command)),
    ?assertEqual(3, erlite_raft_command:schema_version(Command)),
    ?assertEqual([{execute, Sql, Params} || {Sql, Params} <- Mutations],
                 erlite_raft_command:statements(Command)).

invalid_command_fields_are_rejected_test() ->
    ?assertEqual({error, {invalid_transaction_id, <<>>}},
                 erlite_raft_command:new_transaction(
                   <<>>, 0, [{<<"DELETE FROM items WHERE id = ?">>, [1]}])),
    ?assertEqual({error, {invalid_schema_version, -1}},
                 erlite_raft_command:new_transaction(<<"tx">>, -1,
                                                     [{<<"DELETE FROM items WHERE id = ?">>,
                                                       [1]}])),
    ?assertEqual({error, empty_transaction},
                 erlite_raft_command:new_transaction(<<"tx">>, 0, [])),
    ?assertMatch({error, {invalid_command, _}},
                 erlite_raft_command:validate(not_a_command)).

invalid_mutations_and_parameters_are_rejected_test() ->
    ?assertEqual({error, {invalid_mutation, {<<>>, []}}},
                 erlite_raft_command:new_transaction(<<"tx">>, 0, [{<<>>, []}])),
    ?assertEqual({error, {invalid_mutation, {query, <<"SELECT 1">>, []}}},
                 erlite_raft_command:new_transaction(
                   <<"tx">>, 0, [{query, <<"SELECT 1">>, []}])),
    ?assertEqual({error, {invalid_parameter, undefined}},
                 erlite_raft_command:new_transaction(
                   <<"tx">>, 0, [{<<"INSERT INTO items VALUES (?)">>, [undefined]}])).

all_sqlite_parameter_types_are_accepted_test() ->
    ?assertMatch(
       {ok, _},
       erlite_raft_command:new_transaction(
         <<"tx">>, 0,
         [{<<"INSERT INTO items (a, b, c, d) VALUES (?, ?, ?, ?)">>,
           [null, 42, 1.5, <<"value">>]}])).

out_of_policy_sql_is_rejected_by_command_validation_test() ->
    Sql = <<"INSERT INTO items (value) VALUES (random())">>,
    ?assertEqual({error, {unsupported_replicated_sql, Sql}},
                 erlite_raft_command:new_transaction(<<"tx">>, 0, [{Sql, []}])).
