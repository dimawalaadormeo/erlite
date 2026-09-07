-module(erlite_cluster).

-export([init_cluster/1, join/3, leave/2, status/2]).

-spec init_cluster(erlite_cluster_config:config()) -> {ok, map()} | {error, term()}.
init_cluster(Config = #{storage_path := Root, node_name := NodeName,
                        cluster_name := ClusterName}) ->
    case erlite_node_identity:ensure(Root, NodeName) of
        {ok, Identity} -> init_with_identity(Config, Identity, ClusterName);
        Error -> Error
    end.

init_with_identity(#{storage_path := Root}, Identity, ClusterName) ->
    case existing_or_new_cluster_id(Root) of
        {ok, ClusterId} ->
            case erlite_cluster_metadata:ensure(Root, ClusterId, ClusterName) of
                {ok, #{state := active, catalog_server_id := ServerId}} ->
                    status_and_configure(Root, ServerId, 10000);
                {ok, _Initializing} ->
                    ServerId = catalog_server_id(),
                    Node = node_record(Identity, ServerId),
                    case erlite_catalog:start(ClusterId, ClusterName, [Node]) of
                        {ok, _Started, []} ->
                            activate_and_status(Root, ServerId, 10000);
                        {ok, _Started, NotStarted} ->
                            {error, {catalog_not_started, NotStarted}};
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

-spec join(term(), erlite_cluster_config:config(), timeout()) ->
    {ok, map()} | {error, term()} | {timeout, term()}.
join(SeedServer, #{storage_path := Root, node_name := NodeName,
                   cluster_name := ConfiguredName}, Timeout) ->
    case {erlite_catalog:status(SeedServer, Timeout, consistent),
          erlite_node_identity:ensure(Root, NodeName)} of
        {{ok, #{cluster_id := ClusterId, cluster_name := ConfiguredName}},
         {ok, Identity}} ->
            case erlite_cluster_metadata:ensure(
                   Root, ClusterId, ConfiguredName) of
                {ok, _} ->
                    ServerId = catalog_server_id(),
                    case erlite_catalog:join(
                           SeedServer, node_record(Identity, ServerId), Timeout) of
                        ok -> activate_and_status(Root, ServerId, Timeout);
                        Other -> Other
                    end;
                Error -> Error
            end;
        {{ok, #{cluster_name := OtherName}}, _} ->
            {error, {cluster_name_mismatch, OtherName, ConfiguredName}};
        {{error, _Reason} = Error, _} -> Error;
        {{timeout, _Where} = TimeoutError, _} -> TimeoutError;
        {_, {error, _Reason} = Error} -> Error
    end.

-spec leave(file:filename_all(), timeout()) -> ok | {error, term()} | timeout.
leave(Root, Timeout) ->
    case {erlite_cluster_metadata:load(Root), erlite_node_identity:load(Root)} of
        {{ok, #{catalog_server_id := ServerId}}, {ok, #{node_id := NodeId}}} ->
            case erlite_catalog:leave(ServerId, NodeId, Timeout) of
                ok ->
                    case erlite_cluster_metadata:mark_left(Root) of
                        {ok, _} -> ok;
                        Error -> Error
                    end;
                Other -> Other
            end;
        {{error, _Reason} = Error, _} -> Error;
        {_, {error, _Reason} = Error} -> Error
    end.

-spec status(file:filename_all(), timeout()) -> {ok, map()} | {error, term()}.
status(Root, Timeout) ->
    case erlite_cluster_metadata:load(Root) of
        {ok, #{state := active, catalog_server_id := ServerId}} ->
            erlite_catalog:status(ServerId, Timeout, consistent);
        {ok, #{state := State}} -> {error, {cluster_not_active, State}};
        Error -> Error
    end.

activate_and_status(Root, ServerId, Timeout) ->
    case erlite_cluster_metadata:activate(Root, ServerId) of
        {ok, _} -> status_and_configure(Root, ServerId, Timeout);
        Error -> Error
    end.

status_and_configure(Root, ServerId, Timeout) ->
    case erlite_catalog:status(ServerId, Timeout, consistent) of
        {ok, _} = Result ->
            ok = application:set_env(erlite_core, catalog_server, ServerId),
            ok = application:set_env(erlite_core, storage_root, Root),
            ok = application:set_env(
                   erlite_raft, incoming_snapshot_root,
                   filename:join([Root, "snapshots", "incoming"])),
            case whereis(erlite_database_lifecycle) of
                Pid when is_pid(Pid) ->
                    case erlite_database_lifecycle:configure(ServerId, Root) of
                        ok -> Result;
                        Error -> Error
                    end;
                undefined -> Result
            end;
        Error -> Error
    end.

existing_or_new_cluster_id(Root) ->
    case erlite_cluster_metadata:load(Root) of
        {ok, #{cluster_id := ClusterId}} -> {ok, ClusterId};
        {error, cluster_metadata_not_found} -> {ok, crypto:strong_rand_bytes(16)};
        {error, _Reason} = Error -> Error
    end.

catalog_server_id() -> {erlite_catalog, node()}.

node_record(#{node_id := NodeId, node_name := NodeName}, ServerId) ->
    #{node_id => NodeId, node_name => NodeName, server_id => ServerId}.
