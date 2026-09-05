-module(erlite_sqlite_database).

-include_lib("kernel/include/file.hrl").

-export([path/2, create/2, open/2, delete/2]).

-define(MAX_DATABASE_ID_BYTES, 1024).

-type database_id() :: binary().
-type storage_root() :: file:filename_all().

-spec path(storage_root(), database_id()) ->
    {ok, file:filename()} | {error, term()}.
path(StorageRoot, DatabaseId) ->
    case validate(StorageRoot, DatabaseId) of
        {ok, Root} ->
            Digest = binary:encode_hex(crypto:hash(sha256, DatabaseId), lowercase),
            Filename = "db-" ++ binary_to_list(Digest) ++ ".sqlite",
            {ok, filename:join(Root, Filename)};
        {error, _Reason} = Error ->
            Error
    end.

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
                    case erlite_sqlite:close(Connection) of
                        ok -> ok;
                        {error, Reason} -> {error, {close_failed, Reason}}
                    end;
                {error, Reason} ->
                    _ = file:delete(Path),
                    {error, {initialize_failed, Reason}}
            end;
        {error, Reason} ->
            _ = file:delete(Path),
            {error, {permissions_failed, Reason}}
    end.

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

