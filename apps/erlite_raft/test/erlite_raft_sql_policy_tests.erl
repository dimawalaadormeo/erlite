-module(erlite_raft_sql_policy_tests).

-include_lib("eunit/include/eunit.hrl").

supported_parameterized_dml_test() ->
    ?assertEqual(ok,
                 validate(<<"INSERT INTO items (id, name) VALUES (?, ?)">>,
                          [1, <<"first">>])),
    ?assertEqual(ok,
                 validate(<<"update items set name = ? where id = ?">>,
                          [<<"updated">>, 1])),
    ?assertEqual(ok,
                 validate(<<"UPDATE items SET active = ?, name = ?">>,
                          [1, <<"all">>])),
    ?assertEqual(ok,
                 validate(<<"DELETE FROM items WHERE tenant_id = ? AND id = ?">>,
                          [7, 1])).

nondeterministic_functions_are_rejected_test() ->
    assert_unsupported(<<"INSERT INTO items (value) VALUES (random())">>, []),
    assert_unsupported(
      <<"UPDATE items SET created_at = CURRENT_TIMESTAMP WHERE id = ?">>, [1]),
    assert_unsupported(<<"UPDATE items SET value = datetime('now') WHERE id = ?">>,
                       [1]).

queries_subqueries_and_unordered_selection_are_rejected_test() ->
    assert_unsupported(<<"SELECT * FROM items">>, []),
    assert_unsupported(
      <<"INSERT INTO archive (id) SELECT id FROM items LIMIT 1">>, []),
    assert_unsupported(
      <<"UPDATE items SET value = ? WHERE id IN (SELECT id FROM queue LIMIT 1)">>,
      [<<"value">>]).

unsafe_or_out_of_policy_features_are_rejected_test() ->
    Statements = [<<"ATTACH DATABASE ? AS other">>,
                  <<"PRAGMA journal_mode = WAL">>,
                  <<"CREATE TABLE items (id INTEGER)">>,
                  <<"INSERT INTO items (id) VALUES (?); DELETE FROM items">>,
                  <<"INSERT INTO items (id) VALUES (?) RETURNING id">>,
                  <<"UPDATE items SET name = ? COLLATE custom">>,
                  <<"DELETE FROM items">>],
    lists:foreach(fun(Sql) -> assert_unsupported(Sql, []) end, Statements).

invalid_utf8_is_rejected_test() ->
    assert_unsupported(<<255>>, []).

placeholder_count_must_match_parameters_test() ->
    ?assertEqual({error, {parameter_count_mismatch, 2, 1}},
                 validate(<<"INSERT INTO items (id, name) VALUES (?, ?)">>, [1])),
    ?assertEqual({error, {parameter_count_mismatch, 1, 2}},
                 validate(<<"DELETE FROM items WHERE id = ?">>, [1, 2])).

internal_replica_tables_are_reserved_test() ->
    Sql = <<"INSERT INTO __erlite_transactions "
            "(transaction_id) VALUES (?)">>,
    ?assertEqual({error, {reserved_internal_table, Sql}},
                 validate(Sql, [<<"attack">>])).

validate(Sql, Params) ->
    erlite_raft_sql_policy:validate(Sql, Params).

assert_unsupported(Sql, Params) ->
    ?assertEqual({error, {unsupported_replicated_sql, Sql}}, validate(Sql, Params)).
