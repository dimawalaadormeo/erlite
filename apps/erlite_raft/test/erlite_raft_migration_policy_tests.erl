-module(erlite_raft_migration_policy_tests).

-include_lib("eunit/include/eunit.hrl").

safe_ddl_is_accepted_test() ->
    ?assertEqual(ok, validate(<<"CREATE TABLE invoices (id INTEGER PRIMARY KEY)">>)),
    ?assertEqual(ok, validate(<<"CREATE INDEX invoice_id ON invoices(id)">>)).

punctuation_and_whitespace_cannot_hide_unsafe_tokens_test_() ->
    Sql = [<<"CREATE TABLE t (x TEXT DEFAULT(RANDOM()))">>,
           <<"CREATE TABLE t (x TEXT DEFAULT(CURRENT_TIMESTAMP))">>,
           <<"CREATE TABLE t (x TEXT\tDEFAULT\n(random()))">>,
           <<"CREATE TABLE t (x TEXT COLLATE(NOCASE))">>,
           <<"CREATE TABLE t (x INTEGER CHECK(x > 0))">>,
           <<"CREATE TABLE t AS\tSELECT(random())">>,
           <<"CREATE TABLE t (x TEXT GENERATED\tALWAYS AS(x))">>,
           <<"CREATE TABLE t (x TEXT); DROP TABLE other">>,
           <<"CREATE TABLE __erlite_owned (x INTEGER)">>],
    [?_assertEqual({error, unsafe_migration_sql}, validate(Statement))
     || Statement <- Sql].

mixed_case_and_invalid_utf8_are_rejected_test() ->
    ?assertEqual({error, unsafe_migration_sql},
                 validate(<<"cReAtE TaBlE t (x TEXT dEfAuLt(random()))">>)),
    ?assertEqual({error, invalid_migration_sql_encoding},
                 validate(<<"CREATE TABLE t (", 16#ff, ")">>)).

validate(Sql) -> erlite_raft_migration_policy:validate(Sql, []).
