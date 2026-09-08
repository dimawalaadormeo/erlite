-module(erlite_sqlite_schema_policy_tests).

-include_lib("eunit/include/eunit.hrl").

ordinary_relational_schema_is_accepted_test() ->
    with_database(
      fun(Connection) ->
              execute(Connection,
                      <<"CREATE TABLE parents ("
                        "id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)">>),
              execute(Connection,
                      <<"CREATE TABLE children ("
                        "id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, "
                        "FOREIGN KEY(parent_id) REFERENCES parents(id)) STRICT">>),
              ?assertEqual(ok, erlite_sqlite_schema_policy:validate(Connection))
      end).

unsafe_table_features_are_rejected_test_() ->
    Cases = [{default_value,
              <<"CREATE TABLE unsafe (value TEXT DEFAULT CURRENT_TIMESTAMP)">>},
             {generated_column_or_create_as,
              <<"CREATE TABLE unsafe (value INTEGER, doubled INTEGER AS (value * 2))">>},
             {check_constraint,
              <<"CREATE TABLE unsafe (value INTEGER CHECK (value > 0))">>},
             {collation,
              <<"CREATE TABLE unsafe (value TEXT COLLATE NOCASE)">>}],
    [?_test(assert_unsafe_table(Definition, Reason)) || {Reason, Definition} <- Cases].

triggers_and_views_are_rejected_but_plain_indexes_are_accepted_test_() ->
    [?_test(with_schema_object(<<"CREATE TRIGGER unsafe AFTER INSERT ON items "
                                "BEGIN DELETE FROM items WHERE id = NEW.id; END">>,
                               <<"trigger">>, <<"unsafe">>,
                               unsupported_object_type)),
     ?_test(with_schema_object(<<"CREATE VIEW unsafe AS SELECT id FROM items">>,
                               <<"view">>, <<"unsafe">>,
                               unsupported_object_type)),
     ?_test(with_database(
              fun(Connection) ->
                  execute(Connection, <<"CREATE TABLE items (id INTEGER)">>),
                  execute(Connection, <<"CREATE INDEX safe_index ON items(id)">>),
                  ?assertEqual(ok, erlite_sqlite_schema_policy:validate(Connection))
              end))].

owner_exposes_serialized_schema_validation_test() ->
    Root = temporary_root(),
    DatabaseId = <<"schema-policy-owner">>,
    ok = erlite_sqlite_database:create(Root, DatabaseId),
    {ok, Sup} = erlite_sqlite_sup:start_link(),
    unlink(Sup),
    try
        {ok, Owner} = erlite_sqlite_databases:open(Root, DatabaseId),
        ?assertEqual(ok, erlite_sqlite_owner:validate_schema(Owner)),
        {ok, _} = erlite_sqlite_owner:execute(
                    Owner, <<"CREATE TABLE unsafe (value TEXT DEFAULT 'x')">>, []),
        ?assertMatch({error, {unsupported_schema_object, <<"table">>,
                             <<"unsafe">>, default_value}},
                     erlite_sqlite_owner:validate_schema(Owner))
    after
        exit(Sup, shutdown),
        wait_until_dead(Sup),
        _ = erlite_sqlite_database:delete(Root, DatabaseId),
        _ = file:del_dir(Root)
    end.

assert_unsafe_table(Definition, Reason) ->
    with_database(
      fun(Connection) ->
              execute(Connection, Definition),
              ?assertEqual(
                 {error, {unsupported_schema_object, <<"table">>,
                          <<"unsafe">>, Reason}},
                 erlite_sqlite_schema_policy:validate(Connection))
      end).

with_schema_object(Definition, Type, Name, Reason) ->
    with_database(
      fun(Connection) ->
              execute(Connection, <<"CREATE TABLE items (id INTEGER)">>),
              execute(Connection, Definition),
              ?assertEqual({error, {unsupported_schema_object, Type, Name, Reason}},
                           erlite_sqlite_schema_policy:validate(Connection))
      end).

execute(Connection, Sql) ->
    {ok, _} = erlite_sqlite:execute(Connection, Sql, []),
    ok.

with_database(Test) ->
    Path = temporary_database_path(),
    ok = filelib:ensure_dir(Path),
    {ok, Connection} = erlite_sqlite:open(Path),
    try
        ok = erlite_sqlite_schema:initialize(Connection),
        Test(Connection)
    after
        ok = erlite_sqlite:close(Connection),
        ok = delete_if_present(Path)
    end.

temporary_database_path() ->
    filename:join(temporary_root(), "database.sqlite").

temporary_root() ->
    Name = io_lib:format("erlite-schema-policy-~B",
                         [erlang:unique_integer([positive, monotonic])]),
    filename:join(temp_directory(), lists:flatten(Name)).

temp_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.

wait_until_dead(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 ->
        error({process_did_not_stop, Pid})
    end.

delete_if_present(Path) ->
    case file:delete(Path) of
        ok ->
            _ = file:del_dir(filename:dirname(Path)),
            ok;
        {error, enoent} -> ok
    end.
