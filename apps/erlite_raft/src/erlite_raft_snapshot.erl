-module(erlite_raft_snapshot).

-export([create/7, verify/4, verify_backup/1, install/4, restore_as/3,
         transfer/3, export_bundle/1, receive_bundle/3,
         write_export/2, write_export_bundle/4, read_export/1]).

-define(FORMAT_VERSION, 2).

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
            case {sync_file(Image),
                  erlite_sqlite_owner:runtime_identity(Owner)} of
                {ok, {ok, RuntimeIdentity}} ->
                    finish_image(Image, ManifestPath, DatabaseId, Generation,
                                 Index, Term, SchemaVersion, RuntimeIdentity);
                {{error, _Reason} = Error, _} -> Error;
                {_, {error, _Reason} = Error} -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

finish_image(Image, ManifestPath, DatabaseId, Generation, Index, Term,
             SchemaVersion, RuntimeIdentity) ->
    case checksum(Image) of
        {ok, Digest} ->
            Manifest = #{format_version => ?FORMAT_VERSION,
                         database_id => DatabaseId,
                         generation => Generation,
                         raft_index => Index,
                         raft_term => Term,
                         schema_version => SchemaVersion,
                         created_at => erlang:system_time(millisecond),
                         runtime_identity => RuntimeIdentity,
                         image => filename:basename(Image),
                         sha256 => Digest},
            write_manifest(ManifestPath, Manifest);
        {error, _Reason} = Error -> Error
    end.

-spec verify(file:filename_all(), binary(), non_neg_integer(), non_neg_integer()) ->
    {ok, map(), file:filename()} | {error, term()}.
verify(ManifestPath, DatabaseId, Generation, MinimumIndex) ->
    case read_manifest(ManifestPath) of
        {ok, Manifest = #{format_version := ?FORMAT_VERSION,
                          database_id := DatabaseId,
                          generation := Generation,
                          raft_index := Index, raft_term := Term,
                          schema_version := SchemaVersion,
                          created_at := CreatedAt,
                          runtime_identity := RuntimeIdentity,
                          image := ImageName,
                          sha256 := Expected}}
          when is_integer(Index), Index >= MinimumIndex,
               is_integer(Term), Term >= 0,
               is_integer(SchemaVersion), SchemaVersion >= 0,
               is_integer(CreatedAt), CreatedAt > 0, is_list(ImageName),
               ImageName =/= [] ->
            case filename:basename(ImageName) =:= ImageName of
                true ->
                    Image = filename:join(filename:dirname(ManifestPath), ImageName),
                    case checksum(Image) of
                        {ok, Expected} -> verify_image(
                                            Image, Index, RuntimeIdentity,
                                            Manifest);
                        {ok, _Other} -> {error, snapshot_checksum_mismatch};
                        ChecksumError -> ChecksumError
                    end;
                false -> {error, incompatible_snapshot}
            end;
        {ok, _} -> {error, incompatible_snapshot};
        Error -> Error
    end.

-spec verify_backup(file:filename_all()) ->
    {ok, map(), file:filename()} | {error, term()}.
verify_backup(ManifestPath) ->
    case read_manifest(ManifestPath) of
        {ok, #{database_id := DatabaseId, generation := Generation}} ->
            verify(ManifestPath, DatabaseId, Generation, 0);
        {ok, _} -> {error, incompatible_snapshot};
        Error -> Error
    end.

%% Materialize an already verified backup as an offline database with a fresh
%% Raft history.  The caller must not have a running owner for TargetDatabaseId.
-spec restore_as(file:filename_all(), binary(), file:filename_all()) ->
    ok | {error, term()}.
restore_as(StorageRoot, TargetDatabaseId, ManifestPath) ->
    case verify_backup(ManifestPath) of
        {ok, _Manifest, Image} ->
            case erlite_sqlite_database:path(StorageRoot, TargetDatabaseId) of
                {ok, Destination} -> restore_verified_as(Image, Destination);
                Error -> Error
            end;
        Error -> Error
    end.

restore_verified_as(Image, Destination) ->
    Temporary = Destination ++ ".restore-" ++
        integer_to_list(erlang:unique_integer([positive])),
    case filelib:ensure_dir(Destination) of
        ok ->
            case file:copy(Image, Temporary) of
                {ok, _} -> reset_and_activate(Temporary, Destination);
                {error, Reason} -> {error, {snapshot_copy_failed, Reason}}
            end;
        {error, Reason} -> {error, {snapshot_destination, Reason}}
    end.

reset_and_activate(Temporary, Destination) ->
    Result = case erlite_sqlite:open(Temporary) of
                 {ok, Connection} ->
                     Reset = erlite_sqlite_schema:reset_raft_history(Connection),
                     _ = erlite_sqlite:close(Connection),
                     Reset;
                 {error, Reason} -> {error, {snapshot_open_failed, Reason}}
             end,
    case Result of
        ok ->
            ok = file:change_mode(Temporary, 8#600),
            case sync_file(Temporary) of
                ok ->
                    case activate(Temporary, Destination, 0) of
                        {ok, 0} -> ok;
                        Error -> Error
                    end;
                Error -> _ = file:delete(Temporary), Error
            end;
        Error -> _ = file:delete(Temporary), Error
    end.

-spec write_export(file:filename_all(), file:filename_all()) ->
    ok | {error, term()}.
write_export(ManifestPath, ExportPath) ->
    case verify_backup(ManifestPath) of
        {ok, _Verified, _Image} ->
            write_verified_export(ManifestPath, ExportPath);
        Error -> Error
    end.

write_verified_export(ManifestPath, ExportPath) ->
    case export_bundle(ManifestPath) of
        {ok, Manifest, ImageName, ImageBinary} ->
            write_export_bundle(Manifest, ImageName, ImageBinary, ExportPath);
        Error -> Error
    end.

write_export_bundle(Manifest = #{image := ImageName, sha256 := Digest},
                    ImageName, ImageBinary, ExportPath)
  when is_binary(Digest), is_binary(ImageBinary), is_list(ExportPath) ->
    case filename:basename(ImageName) =:= ImageName andalso
         crypto:hash(sha256, ImageBinary) =:= Digest of
        true -> publish_export(
                  ExportPath,
                  term_to_binary({erlite_backup, 1, Manifest, ImageName,
                                  ImageBinary}, [compressed]));
        false -> {error, snapshot_checksum_mismatch}
    end;
write_export_bundle(_, _, _, _) -> {error, incompatible_snapshot}.

publish_export(ExportPath, Binary) ->
    case filelib:ensure_dir(ExportPath) of
        ok ->
            case durable_replace(ExportPath, Binary) of
                ok -> sync_directory(filename:dirname(ExportPath));
                Error -> Error
            end;
        {error, Reason} -> {error, {backup_export_directory, Reason}}
    end.

-spec read_export(file:filename_all()) ->
    {ok, map(), file:filename(), binary()} | {error, term()}.
read_export(ExportPath) ->
    case file:read_file(ExportPath) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                {erlite_backup, 1,
                 Manifest = #{image := ImageName, sha256 := Digest},
                 ImageName, ImageBinary}
                  when is_list(ImageName), is_binary(Digest),
                       is_binary(ImageBinary) ->
                    case filename:basename(ImageName) =:= ImageName andalso
                         crypto:hash(sha256, ImageBinary) =:= Digest of
                        true -> {ok, Manifest, ImageName, ImageBinary};
                        false -> {error, backup_export_checksum_mismatch}
                    end;
                _ -> {error, incompatible_backup_export}
            catch error:badarg -> {error, invalid_backup_export}
            end;
        {error, Reason} -> {error, {backup_export_read_failed, Reason}}
    end.

verify_image(Image, Index, RuntimeIdentity, Manifest) ->
    case erlite_sqlite:open(Image) of
        {ok, Connection} ->
            Result = case erlite_sqlite_compatibility:verify(
                            Connection, RuntimeIdentity) of
                         ok -> verify_applied_index(
                                 Connection, Image, Index, Manifest);
                         {error, _Reason} = Error -> Error
                     end,
            _ = erlite_sqlite:close(Connection),
            Result;
        {error, Reason} -> {error, {snapshot_open_failed, Reason}}
    end.

verify_applied_index(Connection, Image, Index, Manifest) ->
    case erlite_sqlite_schema:last_applied_index(Connection) of
        {ok, Index} -> {ok, Manifest, Image};
        {ok, Other} -> {error, {snapshot_index_mismatch, Index, Other}};
        Error -> Error
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

-spec transfer({atom(), node()}, {atom(), node()}, file:filename_all()) ->
    {ok, file:filename_all()} | {error, term()}.
transfer(Source, Target, ManifestPath) ->
    case member_call(Source, ?MODULE, export_bundle, [ManifestPath]) of
        {ok, Manifest, ImageName, ImageBinary} ->
            member_call(Target, ?MODULE, receive_bundle,
                        [Manifest, ImageName, ImageBinary]);
        Error -> Error
    end.

-spec export_bundle(file:filename_all()) ->
    {ok, map(), file:filename(), binary()} | {error, term()}.
export_bundle(ManifestPath) ->
    case read_manifest(ManifestPath) of
        {ok, Manifest = #{image := ImageName}}
          when is_list(ImageName), ImageName =/= [] ->
            case filename:basename(ImageName) =:= ImageName of
                true ->
                    ImagePath = filename:join(filename:dirname(ManifestPath),
                                              ImageName),
                    case {file:read_file(ManifestPath), file:read_file(ImagePath)} of
                        {{ok, _ManifestBinary}, {ok, ImageBinary}} ->
                            {ok, Manifest, ImageName, ImageBinary};
                        {{error, Reason}, _} ->
                            {error, {snapshot_read_failed, Reason}};
                        {_, {error, Reason}} ->
                            {error, {snapshot_read_failed, Reason}}
                    end;
                false -> {error, incompatible_snapshot}
            end;
        {ok, _} -> {error, incompatible_snapshot};
        Error -> Error
    end.

-spec receive_bundle(map(), file:filename(), binary()) ->
    {ok, file:filename_all()} | {error, term()}.
receive_bundle(Manifest = #{image := ImageName, sha256 := Digest}, ImageName,
               ImageBinary)
  when is_map(Manifest), is_binary(Digest), is_list(ImageName), ImageName =/= [],
       is_binary(ImageBinary) ->
    ManifestBinary = term_to_binary(Manifest, [compressed]),
    receive_verified_bundle(ManifestBinary, ImageName, ImageBinary, Digest);
receive_bundle(_, _, _) -> {error, incompatible_snapshot}.

receive_verified_bundle(ManifestBinary, ImageName, ImageBinary, Digest) ->
    case filename:basename(ImageName) =:= ImageName andalso
         crypto:hash(sha256, ImageBinary) =:= Digest of
        true ->
            SnapshotRoot = application:get_env(
                             erlite_raft, incoming_snapshot_root,
                             filename:join("/tmp", "erlite-incoming-snapshots")),
            ImagePath = filename:join(SnapshotRoot, ImageName),
            ManifestPath = filename:rootname(ImagePath, ".sqlite") ++ ".manifest",
            case filelib:ensure_dir(ImagePath) of
                ok ->
                    case durable_replace(ImagePath, ImageBinary) of
                        ok ->
                            case durable_replace(ManifestPath, ManifestBinary) of
                                ok ->
                                    case sync_directory(SnapshotRoot) of
                                        ok -> {ok, ManifestPath};
                                        {error, Reason} ->
                                            {error, {snapshot_directory_sync_failed,
                                                     Reason}}
                                    end;
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                {error, Reason} -> {error, {snapshot_directory, Reason}}
            end;
        false -> {error, snapshot_checksum_mismatch}
    end.

durable_replace(Path, Binary) ->
    Temporary = Path ++ ".receive-" ++
                integer_to_list(erlang:unique_integer([positive])),
    case file:open(Temporary, [write, binary, exclusive]) of
        {ok, File} ->
            Result = case file:write(File, Binary) of
                         ok -> file:sync(File);
                         Error -> Error
                     end,
            _ = file:close(File),
            case Result of
                ok ->
                    case file:rename(Temporary, Path) of
                        ok -> file:change_mode(Path, 8#600);
                        {error, Reason} ->
                            _ = file:delete(Temporary),
                            {error, {snapshot_receive_activate_failed, Reason}}
                    end;
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, {snapshot_receive_write_failed, Reason}}
            end;
        {error, Reason} -> {error, {snapshot_receive_open_failed, Reason}}
    end.

member_call({_, Node}, Module, Function, Arguments) when Node =:= node() ->
    erlang:apply(Module, Function, Arguments);
member_call({_, Node}, Module, Function, Arguments) ->
    case rpc:call(Node, Module, Function, Arguments) of
        {badrpc, Reason} -> {error, {snapshot_rpc_failed, Node, Reason}};
        Result -> Result
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
                ok ->
                    case sync_directory(filename:dirname(Path)) of
                        ok -> {ok, Path};
                        {error, Reason} ->
                            {error, {manifest_directory_sync_failed, Reason}}
                    end;
                WriteError -> {error, {manifest_write_failed, WriteError}}
            end;
        {error, eexist} -> {error, snapshot_exists};
        {error, Reason} -> {error, {manifest_open_failed, Reason}}
    end.

sync_directory(Path) ->
    case os:find_executable("sync") of
        false -> {error, sync_executable_not_found};
        Executable ->
            Port = open_port(
                     {spawn_executable, Executable},
                     [{args, ["-d", Path]}, exit_status, stderr_to_stdout,
                      binary, use_stdio]),
            wait_sync(Port, <<>>)
    end.

wait_sync(Port, Output) ->
    receive
        {Port, {data, Data}} -> wait_sync(Port, <<Output/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} ->
            {error, {sync_failed, Status, Output}}
    after 5000 ->
        _ = port_close(Port),
        {error, sync_timeout}
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
