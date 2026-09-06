-module(erlite_node_identity).

-export([ensure/2, load/1]).

-define(FORMAT_VERSION, 1).
-define(MAX_NODE_NAME_BYTES, 255).

-type identity() :: #{format_version := pos_integer(),
                      node_id := binary(),
                      node_name := binary()}.
-export_type([identity/0]).

-spec ensure(file:filename_all(), binary()) ->
    {ok, identity()} | {error, term()}.
ensure(StorageRoot, NodeName) ->
    case validate_inputs(StorageRoot, NodeName) of
        {ok, Root} -> ensure_path(identity_path(Root), NodeName);
        {error, _Reason} = Error -> Error
    end.

-spec load(file:filename_all()) -> {ok, identity()} | {error, term()}.
load(StorageRoot) ->
    case validate_root(StorageRoot) of
        {ok, Root} -> read_identity(identity_path(Root));
        {error, _Reason} = Error -> Error
    end.

ensure_path(Path, NodeName) ->
    case read_identity(Path) of
        {ok, #{node_name := NodeName} = Identity} -> {ok, Identity};
        {ok, #{node_name := StoredName}} ->
            {error, {node_name_mismatch, StoredName, NodeName}};
        {error, node_identity_not_found} -> create_identity(Path, NodeName);
        {error, _Reason} = Error -> Error
    end.

create_identity(Path, NodeName) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Identity = #{format_version => ?FORMAT_VERSION,
                         node_id => crypto:strong_rand_bytes(16),
                         node_name => NodeName},
            write_new(Path, Identity);
        {error, Reason} -> {error, {node_directory_failed, Reason}}
    end.

write_new(Path, Identity) ->
    case file:open(Path, [write, binary, exclusive]) of
        {ok, File} ->
            Result = write_and_sync(File, term_to_binary(Identity)),
            _ = file:close(File),
            case Result of
                ok ->
                    case file:change_mode(Path, 8#600) of
                        ok -> {ok, Identity};
                        {error, Reason} -> {error, {node_identity_permissions, Reason}}
                    end;
                {error, Reason} -> {error, {node_identity_write_failed, Reason}}
            end;
        {error, eexist} -> ensure_path(Path, maps:get(node_name, Identity));
        {error, Reason} -> {error, {node_identity_create_failed, Reason}}
    end.

write_and_sync(File, Binary) ->
    case file:write(File, Binary) of
        ok -> file:sync(File);
        {error, _Reason} = Error -> Error
    end.

read_identity(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> decode_identity(Binary);
        {error, enoent} -> {error, node_identity_not_found};
        {error, Reason} -> {error, {node_identity_read_failed, Reason}}
    end.

decode_identity(Binary) ->
    try binary_to_term(Binary, [safe]) of
        Identity = #{format_version := ?FORMAT_VERSION,
                     node_id := NodeId,
                     node_name := NodeName}
          when is_binary(NodeId), byte_size(NodeId) =:= 16,
               is_binary(NodeName), byte_size(NodeName) > 0,
               byte_size(NodeName) =< ?MAX_NODE_NAME_BYTES ->
            {ok, Identity};
        #{format_version := Version} ->
            {error, {unsupported_node_identity_version, Version}};
        _ -> {error, invalid_node_identity}
    catch
        error:badarg -> {error, invalid_node_identity}
    end.

validate_inputs(StorageRoot, NodeName)
  when is_binary(NodeName), byte_size(NodeName) > 0,
       byte_size(NodeName) =< ?MAX_NODE_NAME_BYTES ->
    validate_root(StorageRoot);
validate_inputs(_StorageRoot, _NodeName) ->
    {error, invalid_node_name}.

validate_root(StorageRoot) ->
    case filename:pathtype(StorageRoot) of
        absolute -> {ok, filename:absname(StorageRoot)};
        _ -> {error, storage_root_must_be_absolute}
    end.

identity_path(Root) -> filename:join([Root, "node", "identity"]).
