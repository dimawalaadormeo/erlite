-module(erlite_database_lifecycle).
-behaviour(gen_server).

-export([start_link/0, configure/2, create/1, delete/1, move/3, reconcile/0,
         backup/1, export/2, restore/2, clone/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TIMEOUT, 15000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

configure(CatalogServer, StorageRoot) ->
    gen_server:call(?MODULE, {configure, CatalogServer, StorageRoot}, infinity).

create(DatabaseId) -> gen_server:call(?MODULE, {create, DatabaseId}, infinity).
delete(DatabaseId) -> gen_server:call(?MODULE, {delete, DatabaseId}, infinity).
-spec move(binary(), term(), node()) -> ok | {error, term()} | {timeout, term()}.
move(DatabaseId, Source, TargetNode) ->
    gen_server:call(?MODULE, {move, DatabaseId, Source, TargetNode}, infinity).
reconcile() -> gen_server:call(?MODULE, reconcile, infinity).
backup(DatabaseId) -> gen_server:call(?MODULE, {backup, DatabaseId}, infinity).
export(Backup, ExportPath) ->
    gen_server:call(?MODULE, {export, Backup, ExportPath}, infinity).
restore(DatabaseId, Backup) ->
    gen_server:call(?MODULE, {restore, DatabaseId, Backup, replace}, infinity).
clone(DatabaseId, Backup) ->
    gen_server:call(?MODULE, {restore, DatabaseId, Backup, clone}, infinity).

init([]) ->
    case {application:get_env(erlite_core, catalog_server),
          application:get_env(erlite_core, storage_root)} of
        {{ok, CatalogServer}, {ok, StorageRoot}} ->
            self() ! reconcile,
            {ok, #{catalog_server => CatalogServer, storage_root => StorageRoot}};
        _ -> {ok, #{}}
    end.

handle_call({configure, CatalogServer, StorageRoot}, _From, _State)
  when is_list(StorageRoot) ->
    ok = application:set_env(erlite_core, catalog_server, CatalogServer),
    ok = application:set_env(erlite_core, storage_root, StorageRoot),
    ok = erlite_database_router:configure(CatalogServer),
    State = #{catalog_server => CatalogServer, storage_root => StorageRoot},
    {reply, reconcile_all(State), State};
handle_call({configure, _CatalogServer, _StorageRoot}, _From, State) ->
    {reply, {error, invalid_storage_root}, State};
handle_call({create, DatabaseId}, _From, State) ->
    {reply, create_database(DatabaseId, State), State};
handle_call({delete, DatabaseId}, _From, State) ->
    {reply, delete_database(DatabaseId, State), State};
handle_call({move, DatabaseId, Source, TargetNode}, _From, State) ->
    {reply, move_database(DatabaseId, Source, TargetNode, State), State};
handle_call({backup, DatabaseId}, _From, State) ->
    {reply, backup_database(DatabaseId, State), State};
handle_call({export, Backup, ExportPath}, _From, State) ->
    {reply, export_backup(Backup, ExportPath), State};
handle_call({restore, DatabaseId, Backup, Mode}, _From, State) ->
    {reply, restore_database(DatabaseId, Backup, Mode, State), State};
handle_call(reconcile, _From, State) ->
    {reply, reconcile_all(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) -> {noreply, State}.
handle_info(reconcile, State) ->
    _ = reconcile_all(State),
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

create_database(DatabaseId, State = #{catalog_server := Catalog})
  when is_binary(DatabaseId), byte_size(DatabaseId) > 0,
       byte_size(DatabaseId) =< 1024 ->
    case erlite_catalog:database(Catalog, DatabaseId, ?TIMEOUT, consistent) of
        {error, database_not_found} -> begin_create(DatabaseId, State);
        {ok, Database = #{state := creating}} -> reconcile_one(Database, State);
        {ok, #{state := ready}} -> {error, database_exists};
        {ok, #{state := deleting}} -> {error, database_deleting};
        {ok, #{state := tombstoned, generation := Generation}} ->
            begin_create(DatabaseId, Generation + 1, State);
        Error -> Error
    end;
create_database(_DatabaseId, #{catalog_server := _}) ->
    {error, invalid_database_id};
create_database(_DatabaseId, _State) -> {error, lifecycle_not_configured}.

begin_create(DatabaseId, State) -> begin_create(DatabaseId, 1, State).
begin_create(DatabaseId, Generation,
             State = #{catalog_server := Catalog}) ->
    OperationId = crypto:strong_rand_bytes(16),
    case choose_replicas(DatabaseId, Generation, Catalog) of
        {ok, Replicas} ->
            case erlite_catalog:prepare_database_create(
                   Catalog, DatabaseId, OperationId, Generation, Replicas,
                   ?TIMEOUT) of
                ok -> reconcile_one(#{database_id => DatabaseId,
                                      operation_id => OperationId,
                                      generation => Generation,
                                      replicas => Replicas,
                                      state => creating}, State);
                Error -> Error
            end;
        Error -> Error
    end.

delete_database(DatabaseId, State = #{catalog_server := Catalog}) ->
    case erlite_catalog:database(Catalog, DatabaseId, ?TIMEOUT, consistent) of
        {ok, Database = #{state := ready, generation := Generation}} ->
            OperationId = crypto:strong_rand_bytes(16),
            case erlite_catalog:prepare_database_delete(
                   Catalog, DatabaseId, OperationId, Generation, ?TIMEOUT) of
                ok -> reconcile_one(Database#{state => deleting,
                                               operation_id => OperationId},
                                    State);
                Error -> Error
            end;
        {ok, Database = #{state := deleting}} -> reconcile_one(Database, State);
        {ok, #{state := tombstoned}} -> ok;
        {ok, #{state := creating}} -> {error, database_creating};
        {error, database_not_found} -> ok;
        Error -> Error
    end;
delete_database(_DatabaseId, _State) -> {error, lifecycle_not_configured}.

move_database(DatabaseId, Source, TargetNode,
              State = #{catalog_server := Catalog})
  when is_binary(DatabaseId), is_tuple(Source), is_atom(TargetNode) ->
    case erlite_catalog:database(Catalog, DatabaseId, ?TIMEOUT, consistent) of
        {ok, Database = #{state := ready, generation := Generation,
                          replicas := Replicas}} ->
            case maps:find(movement, Database) of
                {ok, _Movement} -> reconcile_one(Database, State);
                error ->
                    case valid_move_target(TargetNode, Replicas, Catalog) of
                        ok ->
                            OperationId = crypto:strong_rand_bytes(16),
                            Replacement = replacement_server_id(
                                            DatabaseId, Generation + 1,
                                            TargetNode),
                            case erlite_catalog:prepare_database_move(
                                   Catalog, DatabaseId, OperationId, Generation,
                                   Source, Replacement, ?TIMEOUT) of
                                ok -> reconcile_one(
                                        Database#{movement =>
                                                      #{operation_id =>
                                                            OperationId,
                                                        source => Source,
                                                        replacement =>
                                                            Replacement,
                                                        phase => adding}},
                                        State);
                                Error -> Error
                            end;
                        Error -> Error
                    end
            end;
        {ok, #{state := Lifecycle}} ->
            {error, {database_not_ready, Lifecycle}};
        Error -> Error
    end;
move_database(_DatabaseId, _Source, _TargetNode, #{catalog_server := _}) ->
    {error, invalid_database_move};
move_database(_DatabaseId, _Source, _TargetNode, _State) ->
    {error, lifecycle_not_configured}.

backup_database(DatabaseId, #{catalog_server := Catalog,
                              storage_root := StorageRoot}) ->
    case erlite_catalog:database(Catalog, DatabaseId, ?TIMEOUT, consistent) of
        {ok, #{state := ready, generation := Generation}} ->
            BackupRoot = filename:join(StorageRoot, "backups"),
            case erlite_databases:backup(DatabaseId, Generation, BackupRoot) of
                {ok, Source, ManifestPath, Manifest} ->
                    {ok, Manifest#{source_server => Source,
                                   manifest_path => ManifestPath}};
                Error -> Error
            end;
        {ok, #{state := Lifecycle}} ->
            {error, {database_not_ready, Lifecycle}};
        Error -> Error
    end;
backup_database(_DatabaseId, _State) -> {error, lifecycle_not_configured}.

export_backup(#{source_server := Source, manifest_path := ManifestPath},
              ExportPath) when is_list(ExportPath) ->
    case member_call(Source, erlite_raft_snapshot, verify_backup,
                     [ManifestPath]) of
        {ok, _Manifest, _Image} ->
            case member_call(Source, erlite_raft_snapshot, export_bundle,
                             [ManifestPath]) of
                {ok, Manifest, ImageName, ImageBinary} ->
                    erlite_raft_snapshot:write_export_bundle(
                      Manifest, ImageName, ImageBinary, ExportPath);
                Error -> Error
            end;
        Error -> Error
    end;
export_backup(_, _) -> {error, invalid_backup}.

restore_database(DatabaseId, Backup, Mode,
                 State = #{catalog_server := Catalog})
  when is_binary(DatabaseId), (Mode =:= replace orelse Mode =:= clone) ->
    case verify_backup_descriptor(Backup) of
        ok -> begin_restore(DatabaseId, Backup, Mode, Catalog, State);
        Error -> Error
    end;
restore_database(_, _, _, _) -> {error, invalid_database_restore}.

verify_backup_descriptor(#{source_server := {Name, Node} = Source,
                           manifest_path := ManifestPath} = Backup)
  when is_atom(Name), is_atom(Node), is_list(ManifestPath),
       ManifestPath =/= [] ->
    case member_call(Source, erlite_raft_snapshot, verify_backup,
                     [ManifestPath]) of
        {ok, Manifest, _} ->
            Required = [database_id, generation, raft_index, raft_term,
                        schema_version, created_at, sha256],
            case lists:all(fun(K) -> maps:get(K, Backup, undefined) =:=
                                     maps:get(K, Manifest, undefined)
                           end, Required) of
                true -> ok;
                false -> {error, backup_descriptor_mismatch}
            end;
        Error -> Error
    end;
verify_backup_descriptor(_) -> {error, invalid_backup}.

begin_restore(DatabaseId, Backup, Mode, Catalog, State) ->
    case erlite_catalog:database(Catalog, DatabaseId, ?TIMEOUT, consistent) of
        {ok, Database = #{state := restoring}} -> reconcile_one(Database, State);
        {ok, #{state := ready, generation := Generation}} when Mode =:= replace ->
            prepare_restore(DatabaseId, Backup, Mode, Generation,
                            Generation + 1, Catalog, State);
        {error, database_not_found} when Mode =:= clone ->
            prepare_restore(DatabaseId, Backup, Mode, 0, 1, Catalog, State);
        {ok, _} when Mode =:= clone -> {error, database_exists};
        {error, database_not_found} -> {error, database_not_found};
        {ok, #{state := Lifecycle}} ->
            {error, {database_not_ready, Lifecycle}};
        Error -> Error
    end.

prepare_restore(DatabaseId, Backup, Mode, Expected, NewGeneration, Catalog,
                State) ->
    OperationId = crypto:strong_rand_bytes(16),
    case choose_replicas(DatabaseId, NewGeneration, Catalog) of
        {ok, Replicas} ->
            case erlite_catalog:prepare_database_restore(
                   Catalog, DatabaseId, OperationId, Expected, NewGeneration,
                   Replicas, Backup, Mode, ?TIMEOUT) of
                ok ->
                    case erlite_catalog:database(
                           Catalog, DatabaseId, ?TIMEOUT, consistent) of
                        {ok, Database} -> reconcile_one(Database, State);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

reconcile_all(State = #{catalog_server := Catalog}) ->
    case erlite_catalog:recoverable_databases(Catalog, ?TIMEOUT, consistent) of
        {ok, Databases} -> reconcile_list(Databases, State, []);
        Error -> Error
    end;
reconcile_all(_State) -> {error, lifecycle_not_configured}.

reconcile_list([], _State, []) -> ok;
reconcile_list([], _State, Errors) -> {error, {reconciliation_failed, lists:reverse(Errors)}};
reconcile_list([Database | Rest], State, Errors) ->
    case reconcile_one(Database, State) of
        ok -> reconcile_list(Rest, State, Errors);
        {error, _} = Error ->
            reconcile_list(Rest, State,
                           [{maps:get(database_id, Database), Error} | Errors]);
        Other ->
            reconcile_list(Rest, State,
                           [{maps:get(database_id, Database), Other} | Errors])
    end.

reconcile_one(#{database_id := DatabaseId, operation_id := OperationId,
                generation := Generation, replicas := Replicas,
                state := creating},
              #{catalog_server := Catalog, storage_root := StorageRoot}) ->
    Options = #{storage_root => StorageRoot, server_ids => Replicas},
    case erlite_databases:ensure(DatabaseId, Options) of
        {ok, _Pid} -> erlite_catalog:mark_database_ready(
                        Catalog, DatabaseId, OperationId, Generation, ?TIMEOUT);
        Error -> Error
    end;
reconcile_one(#{database_id := DatabaseId, operation_id := OperationId,
                generation := Generation, replicas := Replicas,
                state := restoring, restore := Restore},
              #{catalog_server := Catalog, storage_root := StorageRoot}) ->
    case erlite_databases:placement(DatabaseId) of
        {ok, #{server_ids := Replicas}} ->
            erlite_catalog:finish_database_restore(
              Catalog, DatabaseId, OperationId, Generation, ?TIMEOUT);
        {ok, _OldPlacement} ->
            case retire_previous_restore(DatabaseId, StorageRoot, Restore) of
                ok -> perform_restore(DatabaseId, OperationId, Generation,
                                      Replicas, Restore, Catalog, StorageRoot);
                Error -> Error
            end;
        {error, database_not_found} ->
            perform_restore(DatabaseId, OperationId, Generation, Replicas,
                            Restore, Catalog, StorageRoot);
        Error -> Error
    end;
reconcile_one(#{database_id := DatabaseId, operation_id := OperationId,
                generation := Generation, replicas := Replicas,
                state := deleting},
              #{catalog_server := Catalog, storage_root := StorageRoot}) ->
    Options = #{storage_root => StorageRoot, server_ids => Replicas},
    case erlite_databases:delete_recorded(DatabaseId, Options) of
        ok -> erlite_catalog:tombstone_database(
                Catalog, DatabaseId, OperationId, Generation, ?TIMEOUT);
        Error -> Error
    end;
reconcile_one(#{database_id := DatabaseId,
                           generation := Generation,
                           replicas := Replicas, state := ready,
                           movement := Movement =
                             #{operation_id := OperationId,
                               source := Source, replacement := Replacement,
                               phase := adding}},
              State = #{catalog_server := Catalog}) ->
    case ensure_movement_controller(DatabaseId, Replicas, Movement, State) of
        ok ->
            case erlite_databases:add_replacement(
                   DatabaseId, Source, Replacement, Generation, ?TIMEOUT) of
                ok ->
                    case erlite_catalog:mark_database_replacement_ready(
                           Catalog, DatabaseId, OperationId, Generation,
                           ?TIMEOUT) of
                        ok -> reconcile_one(
                                #{database_id => DatabaseId,
                                  generation => Generation,
                                  replicas => Replicas, state => ready,
                                  movement => Movement#{phase => removing}},
                                State);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end;
reconcile_one(#{database_id := DatabaseId,
                           generation := Generation,
                           replicas := Replicas, state := ready,
                           movement := Movement =
                             #{operation_id := OperationId,
                               source := Source, replacement := Replacement,
                               phase := removing}},
              State = #{catalog_server := Catalog}) ->
    case ensure_movement_controller(DatabaseId, Replicas, Movement, State) of
        ok ->
            case erlite_databases:add_replacement(
                   DatabaseId, Source, Replacement, Generation, ?TIMEOUT) of
                ok ->
                    case erlite_databases:remove_source(
                           DatabaseId, Source, Replacement, ?TIMEOUT) of
                        ok -> erlite_catalog:finish_database_move(
                                Catalog, DatabaseId, OperationId, Generation,
                                ?TIMEOUT);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

retire_previous_restore(DatabaseId, StorageRoot,
                        #{mode := replace, previous_replicas := Replicas}) ->
    erlite_databases:delete_recorded(
      DatabaseId, #{storage_root => StorageRoot, server_ids => Replicas});
retire_previous_restore(_DatabaseId, _StorageRoot, #{mode := clone}) -> ok.

perform_restore(DatabaseId, OperationId, Generation, Replicas, Restore,
                Catalog, StorageRoot) ->
    Backup = maps:get(backup, Restore),
    Source = maps:get(source_server, Backup),
    ManifestPath = maps:get(manifest_path, Backup),
    case erlite_database:restore_resources(DatabaseId, StorageRoot, Replicas,
                                           Source, ManifestPath) of
        ok ->
            Options = #{storage_root => StorageRoot, server_ids => Replicas,
                        ensure_existing => true},
            case erlite_databases:ensure(DatabaseId, Options) of
                {ok, _} -> erlite_catalog:finish_database_restore(
                             Catalog, DatabaseId, OperationId, Generation,
                             ?TIMEOUT);
                Error -> Error
            end;
        Error -> Error
    end.

member_call({_, Node}, Module, Function, Arguments) when Node =:= node() ->
    erlang:apply(Module, Function, Arguments);
member_call({_, Node}, Module, Function, Arguments) ->
    case rpc:call(Node, Module, Function, Arguments, ?TIMEOUT) of
        {badrpc, Reason} -> {error, {backup_rpc_failed, Node, Reason}};
        Result -> Result
    end.

ensure_movement_controller(DatabaseId, Replicas,
                           Movement = #{source := Source,
                                        replacement := Replacement},
                           #{storage_root := StorageRoot}) ->
    case erlite_databases:status(DatabaseId) of
        {ok, _} -> ok;
        {error, database_not_found} ->
            Options = #{storage_root => StorageRoot, server_ids => Replicas,
                        ensure_existing => true,
                        movement => maps:with(
                                      [source, replacement, kind],
                                      #{source => Source,
                                        replacement => Replacement,
                                        kind => maps:get(kind, Movement,
                                                         move)}),
                        allowed_extra_server_ids => [Replacement]},
            case erlite_databases:ensure(DatabaseId, Options) of
                {ok, _Pid} -> ok;
                Error -> Error
            end;
        Error -> Error
    end.

valid_move_target(TargetNode, Replicas, Catalog) ->
    case lists:any(fun({_Name, Node}) -> Node =:= TargetNode end, Replicas) of
        true -> {error, target_already_hosts_replica};
        false ->
            case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
                {ok, #{nodes := Nodes}} ->
                    case lists:any(
                           fun(#{state := active, server_id := {_, Node}}) ->
                                   Node =:= TargetNode;
                              (_) -> false
                           end, Nodes) of
                        true -> ok;
                        false -> {error, target_node_not_active}
                    end;
                Error -> Error
            end
    end.

replacement_server_id(DatabaseId, Generation, TargetNode) ->
    Digest = binary_to_list(erlite_sqlite_database:digest(DatabaseId)),
    {list_to_atom("erlite_db_" ++ Digest ++ "_g" ++
                  integer_to_list(Generation) ++ "_replacement"), TargetNode}.

choose_replicas(DatabaseId, Generation, Catalog) ->
    case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
        {ok, #{nodes := Nodes, databases := Databases}} ->
            Active = lists:sort(
                       [element(2, maps:get(server_id, NodeRecord))
                        || NodeRecord <- Nodes,
                           maps:get(state, NodeRecord, active) =:= active]),
            Options0 = application:get_env(erlite_core, placement_options, #{}),
            Options = erlite_placement:effective_options(DatabaseId, Options0),
            case erlite_placement:choose_initial(DatabaseId, Databases,
                                                 Active, Options) of
                {ok, Three} ->
                    {ok, make_server_ids(DatabaseId, Generation, Three)};
                {error, insufficient_placement_capacity} ->
                    {error, insufficient_active_nodes};
                Error -> Error
            end;
        Error -> Error
    end.

make_server_ids(DatabaseId, Generation, Nodes) ->
    Digest = binary_to_list(erlite_sqlite_database:digest(DatabaseId)),
    [{list_to_atom("erlite_db_" ++ Digest ++ "_g" ++
                   integer_to_list(Generation) ++ "_r" ++ integer_to_list(N)),
      ErlangNode}
     || {N, ErlangNode} <- lists:zip([1, 2, 3], Nodes)].
