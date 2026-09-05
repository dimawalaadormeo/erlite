-module(erlite_raft_snapshot).

-export([create/7, verify/4, install/4]).

-define(FORMAT_VERSION, 1).

-spec create(pid(), file:filename_all(), binary(), non_neg_integer(),
             non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    {ok, file:filename()} | {error, term()}.
create(Owner, SnapshotRoot, DatabaseId, Generation, Index, Term, SchemaVersion) ->
    Base = snapshot_base(DatabaseId, Generation, Index),
    Image = filename:join(SnapshotRoot, Base ++ ".sqlite"),
    ManifestPath = filename:join(SnapshotRoot, Base ++ ".manifest"),
    case filelib:ensure_dir(Image) of
        ok -> create_image(Owner, Image, ManifestPath, DatabaseId, Generation,
                           Index, Term, SchemaVersion);
        {error, Reason} -> {error, {snapshot_directory, Reason}}
    end.

create_image(Owner, Image, ManifestPath, DatabaseId, Generation, Index, Term,
             SchemaVersion) ->
    _ = file:delete(Image),
    case erlite_sqlite_owner:snapshot_into(Owner, Image) of
        ok ->
            case checksum(Image) of
                {ok, Digest} ->
                    Manifest = #{format_version => ?FORMAT_VERSION,
                                 database_id => DatabaseId,
                                 generation => Generation,
                                 raft_index => Index,
                                 raft_term => Term,
                                 schema_version => SchemaVersion,
                                 image => filename:basename(Image),
                                 sha256 => Digest},
                    write_manifest(ManifestPath, Manifest);
                Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-spec verify(file:filename_all(), binary(), non_neg_integer(), non_neg_integer()) ->
    {ok, map(), file:filename()} | {error, term()}.
verify(ManifestPath, DatabaseId, Generation, MinimumIndex) ->
    case read_manifest(ManifestPath) of
        {ok, Manifest = #{format_version := ?FORMAT_VERSION,
                          database_id := DatabaseId,
                          generation := Generation,
                          raft_index := Index,
                          image := ImageName,
                          sha256 := Expected}}
          when is_integer(Index), Index >= MinimumIndex, is_list(ImageName),
               ImageName =/= [] ->
            case filename:basename(ImageName) =:= ImageName of
                true ->
                    Image = filename:join(filename:dirname(ManifestPath), ImageName),
                    case checksum(Image) of
                        {ok, Expected} -> verify_applied_index(Image, Index, Manifest);
                        {ok, _Other} -> {error, snapshot_checksum_mismatch};
                        ChecksumError -> ChecksumError
                    end;
                false -> {error, incompatible_snapshot}
            end;
        {ok, _} -> {error, incompatible_snapshot};
        Error -> Error
    end.

verify_applied_index(Image, Index, Manifest) ->
    case erlite_sqlite:open(Image) of
        {ok, Connection} ->
            Result = case erlite_sqlite_schema:last_applied_index(Connection) of
                         {ok, Index} -> {ok, Manifest, Image};
                         {ok, Other} -> {error, {snapshot_index_mismatch, Index, Other}};
                         Error -> Error
                     end,
            _ = erlite_sqlite:close(Connection),
            Result;
        {error, Reason} -> {error, {snapshot_open_failed, Reason}}
    end.

-spec install(file:filename_all(), binary(), non_neg_integer(), file:filename_all()) ->
    {ok, non_neg_integer()} | {error, term()}.
install(StorageRoot, DatabaseId, Generation, ManifestPath) ->
    case verify(ManifestPath, DatabaseId, Generation, 0) of
        {ok, #{raft_index := Index}, Image} ->
            case erlite_sqlite_databases:close(StorageRoot, DatabaseId) of
                ok ->
                    case erlite_sqlite_database:path(StorageRoot, DatabaseId) of
                        {ok, Destination} ->
                            install_verified(Image, Destination, Index);
                        Error -> Error
                    end;
                {error, _Reason} = Error -> Error
            end;
        Error -> Error
    end.

install_verified(Image, Destination, Index) ->
    Temporary = Destination ++ ".install-" ++
                integer_to_list(erlang:unique_integer([positive])),
    case filelib:ensure_dir(Destination) of
        ok -> copy_and_activate(Image, Temporary, Destination, Index);
        {error, Reason} -> {error, {snapshot_destination, Reason}}
    end.

copy_and_activate(Image, Temporary, Destination, Index) ->
    case file:copy(Image, Temporary) of
        {ok, _} ->
            ok = file:change_mode(Temporary, 8#600),
            case sync_file(Temporary) of
                ok -> activate(Temporary, Destination, Index);
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, {snapshot_sync_failed, Reason}}
            end;
        {error, Reason} -> {error, {snapshot_copy_failed, Reason}}
    end.

activate(Temporary, Destination, Index) ->
    case file:rename(Temporary, Destination) of
                ok ->
                    _ = file:delete(Destination ++ "-wal"),
                    _ = file:delete(Destination ++ "-shm"),
                    {ok, Index};
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, {snapshot_activate_failed, Reason}}
    end.

sync_file(Path) ->
    case file:open(Path, [read, write, binary]) of
        {ok, File} ->
            Result = file:sync(File),
            _ = file:close(File),
            Result;
        {error, _Reason} = Error -> Error
    end.

write_manifest(Path, Manifest) ->
    case file:open(Path, [write, binary, exclusive]) of
        {ok, File} ->
            Result = case file:write(File, term_to_binary(Manifest, [compressed])) of
                         ok -> file:sync(File);
                         Error -> Error
                     end,
            _ = file:close(File),
            case Result of
                ok -> {ok, Path};
                WriteError -> {error, {manifest_write_failed, WriteError}}
            end;
        {error, eexist} -> {error, snapshot_exists};
        {error, Reason} -> {error, {manifest_open_failed, Reason}}
    end.

read_manifest(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            try {ok, binary_to_term(Binary, [safe])}
            catch error:badarg -> {error, invalid_snapshot_manifest}
            end;
        {error, Reason} -> {error, {manifest_read_failed, Reason}}
    end.

checksum(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, crypto:hash(sha256, Binary)};
        {error, Reason} -> {error, {snapshot_read_failed, Reason}}
    end.

snapshot_base(DatabaseId, Generation, Index) ->
    Digest = binary:encode_hex(crypto:hash(sha256, DatabaseId), lowercase),
    binary_to_list(Digest) ++ "-" ++ integer_to_list(Generation) ++ "-" ++
        integer_to_list(Index).
