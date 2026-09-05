-module(erlite_sqlite_database_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

database_id_is_not_used_as_a_filename_test() ->
    Root = temporary_root(),
    UnsafeId = <<"../../merchant/with spaces">>,
    {ok, Path1} = erlite_sqlite_database:path(Root, UnsafeId),
    {ok, Path2} = erlite_sqlite_database:path(Root, UnsafeId),
    ?assertEqual(Path1, Path2),
    ?assertEqual(filename:absname(Root), filename:dirname(Path1)),
    ?assertEqual(nomatch, re:run(filename:basename(Path1), "merchant|/|\\\\")),
    ?assertMatch({match, _},
                 re:run(filename:basename(Path1), "^db-[0-9a-f]{64}\\.sqlite$")).

invalid_inputs_are_rejected_test() ->
    Root = temporary_root(),
    ?assertEqual({error, invalid_database_id}, erlite_sqlite_database:path(Root, <<>>)),
    ?assertEqual({error, invalid_database_id}, erlite_sqlite_database:path(Root, not_binary)),
    ?assertEqual({error, database_id_too_long},
                 erlite_sqlite_database:path(Root, binary:copy(<<"x">>, 1025))),
    ?assertEqual({error, storage_root_must_be_absolute},
                 erlite_sqlite_database:path("relative", <<"merchant-1">>)).

create_open_and_idempotent_delete_test() ->
    Root = temporary_root(),
    DatabaseId = <<"merchant-1">>,
    try
        ?assertEqual(ok, erlite_sqlite_database:create(Root, DatabaseId)),
        ?assertEqual({error, database_exists},
                     erlite_sqlite_database:create(Root, DatabaseId)),
        {ok, Path} = erlite_sqlite_database:path(Root, DatabaseId),
        {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
        ?assertEqual(0, Mode band 8#077),
        {ok, Connection} = erlite_sqlite_database:open(Root, DatabaseId),
        {ok, _} = erlite_sqlite:execute(Connection,
                                        <<"CREATE TABLE test (value TEXT)">>,
                                        []),
        ok = erlite_sqlite:close(Connection),
        ?assertEqual(ok, erlite_sqlite_database:delete(Root, DatabaseId)),
        ?assertEqual(ok, erlite_sqlite_database:delete(Root, DatabaseId)),
        ?assertEqual({error, database_not_found},
                     erlite_sqlite_database:open(Root, DatabaseId))
    after
        cleanup_root(Root)
    end.

symlink_database_file_is_rejected_test() ->
    Root = temporary_root(),
    DatabaseId = <<"merchant-symlink">>,
    Target = Root ++ "-target",
    try
        ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
        ok = file:write_file(Target, <<"do not touch">>),
        {ok, Path} = erlite_sqlite_database:path(Root, DatabaseId),
        ok = file:make_symlink(Target, Path),
        ?assertEqual({error, database_file_is_symlink},
                     erlite_sqlite_database:open(Root, DatabaseId)),
        ?assertEqual({error, database_file_is_symlink},
                     erlite_sqlite_database:delete(Root, DatabaseId)),
        ?assertEqual({ok, <<"do not touch">>}, file:read_file(Target)),
        ok = file:delete(Path)
    after
        _ = file:delete(Target),
        cleanup_root(Root)
    end.

temporary_root() ->
    Name = io_lib:format("erlite-databases-~B",
                         [erlang:unique_integer([positive, monotonic])]),
    filename:join(temp_directory(), lists:flatten(Name)).

temp_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.

cleanup_root(Root) ->
    case file:list_dir(Root) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> _ = file:delete(filename:join(Root, Name)) end,
                          Names),
            _ = file:del_dir(Root),
            ok;
        {error, enoent} ->
            ok
    end.

