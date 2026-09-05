-module(erlite_raft_phase1_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         commit_apply_and_restart_catch_up/1]).

all() ->
    [commit_apply_and_restart_catch_up].

init_per_suite(Config) ->
    Root = filename:join("/tmp", "erlite-raft-phase1-" ++
                         integer_to_list(erlang:unique_integer([positive]))),
    RaDir = filename:join(Root, "ra"),
    DbDir = filename:join(Root, "db"),
    RecoveryDir = filename:join(Root, "recovery"),
    SnapshotDir = filename:join(Root, "snapshots"),
    ok = filelib:ensure_dir(filename:join(RaDir, "placeholder")),
    {ok, _} = application:ensure_all_started(erlite_sqlite),
    {ok, _} = ra:start([{data_dir, RaDir}]),
    ok = application:start(erlite_raft),
    [{root, Root}, {db_dir, DbDir}, {recovery_dir, RecoveryDir},
     {snapshot_dir, SnapshotDir} | Config].

end_per_suite(Config) ->
    Members = member_ids(),
    lists:foreach(fun(Member) -> _ = ra:force_delete_server(default, Member) end,
                  Members),
    _ = application:stop(erlite_raft),
    _ = application:stop(ra),
    cleanup_tree(proplists:get_value(root, Config)),
    ok.

commit_apply_and_restart_catch_up(Config) ->
    DbDir = proplists:get_value(db_dir, Config),
    DatabaseId = <<"phase1-database">>,
    ok = erlite_sqlite_databases:create(DbDir, DatabaseId),
    {ok, Owner1} = erlite_sqlite_databases:open(DbDir, DatabaseId),
    {ok, _} = erlite_sqlite_owner:execute(
                Owner1, <<"CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)">>, []),
    Members = member_ids(),
    {ok, StartedMembers, []} =
        erlite_raft_cluster:start(<<"erlite_phase1_test">>, member_names()),
    Members = lists:sort(StartedMembers),
    Command1 = command(<<"tx-1">>, 1, <<"one">>),
    {ok, FirstIndex, Leader} =
        erlite_raft_applier:submit_and_apply(hd(Members), Command1, Owner1, 10000),
    {ok, FirstIndex} = erlite_sqlite_owner:last_applied_index(Owner1),
    SnapshotDir = proplists:get_value(snapshot_dir, Config),
    {ok, Manifest} = erlite_raft_snapshot:create(
                       Owner1, SnapshotDir, DatabaseId, 1,
                       FirstIndex, 1, 0),
    ok = erlite_sqlite_databases:close(DbDir, DatabaseId),
    Command2 = command(<<"tx-2">>, 2, <<"two">>),
    {ok, SecondIndex, _} = erlite_raft_cluster:submit(Leader, Command2, 10000),
    true = SecondIndex > FirstIndex,
    {ok, Owner2} = erlite_sqlite_databases:open(DbDir, DatabaseId),
    {ok, SecondIndex} = erlite_raft_applier:catch_up(Leader, Owner2, 10000),
    {ok, #{rows := [[2]]}} =
        erlite_sqlite_owner:query(Owner2, <<"SELECT count(*) FROM items">>, []),
    RecoveryDir = proplists:get_value(recovery_dir, Config),
    {ok, FirstIndex} = erlite_raft_snapshot:install(
                         RecoveryDir, DatabaseId, 1, Manifest),
    {ok, RecoveryOwner} = erlite_sqlite_databases:open(RecoveryDir, DatabaseId),
    {ok, SecondIndex} = erlite_raft_applier:catch_up(
                          Leader, RecoveryOwner, 10000),
    {ok, #{rows := [[1, <<"one">>], [2, <<"two">>]]}} =
        erlite_sqlite_owner:query(
          RecoveryOwner, <<"SELECT id, value FROM items ORDER BY id">>, []),
    {ok, ManifestBinary} = file:read_file(Manifest),
    #{image := ImageName} = binary_to_term(ManifestBinary, [safe]),
    ImagePath = filename:join(filename:dirname(Manifest), ImageName),
    ok = file:write_file(ImagePath, <<"corrupt">>, [append]),
    {error, snapshot_checksum_mismatch} =
        erlite_raft_snapshot:verify(Manifest, DatabaseId, 1, 0),
    ok.

member_names() -> [erlite_phase1_1, erlite_phase1_2, erlite_phase1_3].
member_ids() -> [{Name, node()} || Name <- member_names()].

command(TransactionId, Id, Value) ->
    {ok, Command} = erlite_raft_command:new_transaction(
                      TransactionId, 0,
                      [{<<"INSERT INTO items (id, value) VALUES (?, ?)">>,
                        [Id, Value]}]),
    Command.

cleanup_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(
              fun(Name) ->
                      Child = filename:join(Path, Name),
                      case filelib:is_dir(Child) of
                          true -> cleanup_tree(Child);
                          false -> _ = file:delete(Child)
                      end
              end, Names),
            _ = file:del_dir(Path),
            ok;
        {error, enoent} -> ok
    end.
