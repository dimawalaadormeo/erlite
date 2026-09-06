-module(erlite_cluster_metadata).

-export([ensure/3, activate/2, mark_left/1, load/1]).

-define(FORMAT_VERSION, 1).

-spec ensure(file:filename_all(), binary(), binary()) -> {ok, map()} | {error, term()}.
ensure(Root, ClusterId, ClusterName) ->
    Path = path(Root),
    case load(Root) of
        {ok, #{cluster_id := ClusterId, cluster_name := ClusterName} = Metadata} ->
            {ok, Metadata};
        {ok, _Other} -> {error, cluster_identity_mismatch};
        {error, cluster_metadata_not_found} ->
            Metadata = #{format_version => ?FORMAT_VERSION,
                         cluster_id => ClusterId,
                         cluster_name => ClusterName,
                         state => initializing},
            write_new(Path, Metadata);
        Error -> Error
    end.

-spec activate(file:filename_all(), term()) -> {ok, map()} | {error, term()}.
activate(Root, CatalogServerId) -> update(Root, active, CatalogServerId).

-spec mark_left(file:filename_all()) -> {ok, map()} | {error, term()}.
mark_left(Root) -> update(Root, left, undefined).

-spec load(file:filename_all()) -> {ok, map()} | {error, term()}.
load(Root) ->
    case file:read_file(path(Root)) of
        {ok, Binary} -> decode(Binary);
        {error, enoent} -> {error, cluster_metadata_not_found};
        {error, Reason} -> {error, {cluster_metadata_read_failed, Reason}}
    end.

update(Root, State, CatalogServerId) ->
    case load(Root) of
        {ok, Metadata} ->
            New = Metadata#{state => State, catalog_server_id => CatalogServerId},
            case replace(path(Root), New) of ok -> {ok, New}; Error -> Error end;
        Error -> Error
    end.

write_new(Path, Metadata) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:open(Path, [write, binary, exclusive]) of
                {ok, File} -> finish_write(File, Path, Metadata);
                {error, eexist} ->
                    ensure(filename:dirname(filename:dirname(Path)),
                           maps:get(cluster_id, Metadata),
                           maps:get(cluster_name, Metadata));
                {error, Reason} -> {error, {cluster_metadata_create_failed, Reason}}
            end;
        {error, Reason} -> {error, {cluster_metadata_directory_failed, Reason}}
    end.

replace(Path, Metadata) ->
    Temporary = Path ++ ".tmp-" ++ integer_to_list(erlang:unique_integer([positive])),
    case file:open(Temporary, [write, binary, exclusive]) of
        {ok, File} ->
            case finish_write(File, Temporary, Metadata) of
                {ok, _} ->
                    case file:rename(Temporary, Path) of
                        ok -> ok;
                        {error, Reason} ->
                            _ = file:delete(Temporary),
                            {error, {cluster_metadata_activate_failed, Reason}}
                    end;
                {error, _Reason} = Error -> Error
            end;
        {error, Reason} -> {error, {cluster_metadata_create_failed, Reason}}
    end.

finish_write(File, Path, Metadata) ->
    Result = case file:write(File, term_to_binary(Metadata)) of
                 ok -> file:sync(File);
                 Error -> Error
             end,
    _ = file:close(File),
    case Result of
        ok ->
            case file:change_mode(Path, 8#600) of
                ok -> {ok, Metadata};
                {error, Reason} -> {error, {cluster_metadata_permissions, Reason}}
            end;
        {error, Reason} -> {error, {cluster_metadata_write_failed, Reason}}
    end.

decode(Binary) ->
    try binary_to_term(Binary, [safe]) of
        Metadata = #{format_version := ?FORMAT_VERSION,
                     cluster_id := Id, cluster_name := Name,
                     state := State}
          when is_binary(Id), byte_size(Id) =:= 16, is_binary(Name),
               (State =:= initializing orelse State =:= active orelse State =:= left) ->
            {ok, Metadata};
        #{format_version := Version} ->
            {error, {unsupported_cluster_metadata_version, Version}};
        _ -> {error, invalid_cluster_metadata}
    catch error:badarg -> {error, invalid_cluster_metadata}
    end.

path(Root) -> filename:join([filename:absname(Root), "node", "cluster"]).
