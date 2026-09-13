-module(erlite_sqlite_database).

-include_lib("kernel/include/file.hrl").

-export([path/2, digest/1, create/2, open/2, open_writer/2, delete/2]).

-define(MAX_DATABASE_ID_BYTES, 1024).

-type database_id() :: binary().
-type storage_root() :: file:filename_all().

-spec path(storage_root(), database_id()) ->
    {ok, file:filename()} | {error, term()}.
path(StorageRoot, DatabaseId) ->
    case validate(StorageRoot, DatabaseId) of
        {ok, Root} ->
            Digest = digest(DatabaseId),
            Filename = "db-" ++ binary_to_list(Digest) ++ ".sqlite",
            {ok, filename:join(Root, Filename)};
        {error, _Reason} = Error ->
            Error
    end.

-spec digest(database_id()) -> binary().
digest(DatabaseId) when is_binary(DatabaseId), byte_size(DatabaseId) > 0,
                        byte_size(DatabaseId) =< ?MAX_DATABASE_ID_BYTES ->
    binary:encode_hex(crypto:hash(sha256, DatabaseId), lowercase).

-spec create(storage_root(), database_id()) -> ok | {error, term()}.
create(StorageRoot, DatabaseId) ->
    case path(StorageRoot, DatabaseId) of
        {ok, Path} -> create_path(Path);
        {error, _Reason} = Error -> Error
    end.

-spec open(storage_root(), database_id()) ->
    {ok, erlite_sqlite:connection()} | {error, term()}.
open(StorageRoot, DatabaseId) ->
    case path(StorageRoot, DatabaseId) of
        {ok, Path} -> open_path(Path);
        {error, _Reason} = Error -> Error
    end.

-spec open_writer(storage_root(), database_id()) ->
    {ok, erlite_sqlite:connection()} | {error, term()}.
open_writer(StorageRoot, DatabaseId) ->
    case open(StorageRoot, DatabaseId) of
        {ok, Connection} -> configure_writer(Connection);
        {error, _Reason} = Error -> Error
    end.

-spec delete(storage_root(), database_id()) -> ok | {error, term()}.
delete(StorageRoot, DatabaseId) ->
    case path(StorageRoot, DatabaseId) of
        {ok, Path} -> delete_path(Path);
        {error, _Reason} = Error -> Error
    end.

validate(StorageRoot, DatabaseId)
  when is_binary(DatabaseId),
       byte_size(DatabaseId) > 0,
       byte_size(DatabaseId) =< ?MAX_DATABASE_ID_BYTES ->
    Root = filename:absname(StorageRoot),
    case filename:pathtype(StorageRoot) of
        absolute -> {ok, Root};
        _ -> {error, storage_root_must_be_absolute}
    end;
validate(_StorageRoot, DatabaseId) when not is_binary(DatabaseId) ->
    {error, invalid_database_id};
validate(_StorageRoot, <<>>) ->
    {error, invalid_database_id};
validate(_StorageRoot, _DatabaseId) ->
    {error, database_id_too_long}.

create_path(Path) ->
    case filelib:ensure_dir(Path) of
        ok -> create_file(Path);
        {error, Reason} -> {error, {storage_directory, Reason}}
    end.

create_file(Path) ->
    case file:open(Path, [write, binary, exclusive]) of
        {ok, File} ->
            ok = file:close(File),
            initialize_file(Path);
        {error, eexist} ->
            {error, database_exists};
        {error, Reason} ->
            {error, {create_failed, Reason}}
    end.

initialize_file(Path) ->
    case file:change_mode(Path, 8#600) of
        ok ->
            case erlite_sqlite:open(Path) of
                {ok, Connection} ->
                    initialize_connection(Path, Connection);
                {error, Reason} ->
                    _ = file:delete(Path),
                    {error, {initialize_failed, Reason}}
            end;
        {error, Reason} ->
            _ = file:delete(Path),
            {error, {permissions_failed, Reason}}
    end.

initialize_connection(Path, Connection) ->
    case configure_writer(Connection) of
        {ok, Connection} ->
            case erlite_sqlite_schema:initialize(Connection) of
                ok ->
                    case erlite_sqlite:close(Connection) of
                        ok -> ok;
                        {error, Reason} -> {error, {close_failed, Reason}}
                    end;
                {error, Reason} ->
                    _ = erlite_sqlite:close(Connection),
                    _ = delete_path(Path),
                    {error, {schema_initialization_failed, Reason}}
            end;
        {error, Reason} ->
            _ = delete_path(Path),
            {error, {writer_configuration_failed, Reason}}
    end.

configure_writer(Connection) ->
    case erlite_sqlite:query(Connection, <<"PRAGMA journal_mode = WAL">>, []) of
        {ok, #{rows := [[Mode]]}} ->
            case lowercase_binary(Mode) of
                <<"wal">> -> configure_synchronous(Connection);
                Other -> close_with_error(
                           Connection, {unexpected_journal_mode, Other})
            end;
        {ok, Result} ->
            close_with_error(Connection, {unexpected_journal_mode_result,
                                          Result});
        {error, Reason} ->
            close_with_error(Connection, {journal_mode_failed, Reason})
    end.

configure_synchronous(Connection) ->
    case erlite_sqlite:execute(
           Connection, <<"PRAGMA synchronous = FULL">>, []) of
        {ok, _} ->
            case erlite_sqlite:query(
                   Connection, <<"PRAGMA synchronous">>, []) of
                {ok, #{rows := [[2]]}} -> {ok, Connection};
                {ok, Result} -> close_with_error(
                                  Connection,
                                  {unexpected_synchronous_result, Result});
                {error, Reason} -> close_with_error(
                                     Connection,
                                     {synchronous_verify_failed, Reason})
            end;
        {error, Reason} ->
            close_with_error(Connection, {synchronous_full_failed, Reason})
    end.

close_with_error(Connection, Reason) ->
    _ = erlite_sqlite:close(Connection),
    {error, Reason}.

lowercase_binary(Value) when is_binary(Value) ->
    unicode:characters_to_binary(string:lowercase(
                                   unicode:characters_to_list(Value)));
lowercase_binary(Value) -> Value.


open_path(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> erlite_sqlite:open(Path);
        {ok, #file_info{type = symlink}} -> {error, database_file_is_symlink};
        {ok, #file_info{type = Type}} -> {error, {invalid_database_file_type, Type}};
        {error, enoent} -> {error, database_not_found};
        {error, Reason} -> {error, {database_stat_failed, Reason}}
    end.

delete_path(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} ->
            case file:delete(Path) of
                ok -> delete_auxiliary_files(Path);
                {error, Reason} -> {error, {delete_failed, Reason}}
            end;
        {ok, #file_info{type = symlink}} -> {error, database_file_is_symlink};
        {ok, #file_info{type = Type}} -> {error, {invalid_database_file_type, Type}};
        {error, enoent} -> delete_auxiliary_files(Path);
        {error, Reason} -> {error, {database_stat_failed, Reason}}
    end.

delete_auxiliary_files(Path) ->
    delete_files([Path ++ "-wal", Path ++ "-shm"]).

delete_files([]) ->
    ok;
delete_files([Path | Rest]) ->
    case file:delete(Path) of
        ok -> delete_files(Rest);
        {error, enoent} -> delete_files(Rest);
        {error, Reason} -> {error, {auxiliary_delete_failed, Path, Reason}}
    end.
