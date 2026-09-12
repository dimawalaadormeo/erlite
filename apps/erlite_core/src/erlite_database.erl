-module(erlite_database).
-behaviour(gen_server).

-export([start_link/2, delete_resources/2, cleanup_stale_replica/3,
         restore_resources/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RPC_TIMEOUT, 15000).

start_link(DatabaseId, Options) ->
    gen_server:start_link(?MODULE, {DatabaseId, Options}, []).

delete_resources(DatabaseId, #{storage_root := StorageRoot,
                               server_ids := ServerIds}) ->
    Roots = replica_roots(StorageRoot, ServerIds),
    case stop_servers(ServerIds) of
        ok ->
            ok = close_replicas(DatabaseId, Roots),
            delete_replicas(DatabaseId, Roots);
        Error -> Error
    end;
delete_resources(_DatabaseId, _Options) -> {error, invalid_database_options}.

cleanup_stale_replica(DatabaseId, StorageRoot, ServerId) ->
    Root = replica_root(StorageRoot, ServerId, 1),
    _ = member_call(ServerId, ra, force_delete_server, [default, ServerId]),
    _ = member_call(ServerId, erlite_sqlite_databases, close,
                    [Root, DatabaseId]),
    case member_call(ServerId, erlite_sqlite_databases, delete,
                     [Root, DatabaseId]) of
        ok -> ok;
        {error, database_not_found} -> ok;
        Error -> Error
    end.

restore_resources(DatabaseId, StorageRoot, ServerIds, Source, ManifestPath) ->
    case member_call(Source, erlite_raft_snapshot, export_bundle,
                     [ManifestPath]) of
        {ok, Manifest, ImageName, ImageBinary} ->
            Roots = replica_roots(StorageRoot, ServerIds),
            restore_resource_list(DatabaseId, maps:to_list(Roots), Manifest,
                                  ImageName, ImageBinary);
        Error -> Error
    end.

restore_resource_list(_DatabaseId, [], _Manifest, _ImageName, _ImageBinary) ->
    ok;
restore_resource_list(DatabaseId, [{ServerId, Root} | Rest], Manifest,
                      ImageName, ImageBinary) ->
    case member_call(ServerId, erlite_raft_snapshot, receive_bundle,
                     [Manifest, ImageName, ImageBinary]) of
        {ok, ReceivedManifest} ->
            case member_call(ServerId, erlite_raft_snapshot, restore_as,
                             [Root, DatabaseId, ReceivedManifest]) of
                ok -> restore_resource_list(DatabaseId, Rest, Manifest,
                                            ImageName, ImageBinary);
                Error -> Error
            end;
        Error -> Error
    end.

init({DatabaseId, #{storage_root := StorageRoot,
                    server_ids := ConfiguredServerIds} = Options}) ->
    ServerIds = effective_server_ids(ConfiguredServerIds, Options),
    case open_for_init(StorageRoot, DatabaseId, ConfiguredServerIds,
                       ServerIds, Options) of
        {ok, Replicas, Roots, RuntimeIdentity} ->
            ClusterName = cluster_name(DatabaseId),
            AllowedMembers = lists:usort(
                               ServerIds ++
                               maps:get(allowed_extra_server_ids, Options, [])),
            case ensure_raft_cluster(ClusterName, ServerIds, AllowedMembers,
                                     RuntimeIdentity) of
                {ok, _Started, []} ->
                    {ok, #{database_id => DatabaseId,
                           storage_root => StorageRoot,
                           server_ids => ServerIds,
                           replicas => Replicas,
                           replica_roots => Roots,
                           runtime_identity => RuntimeIdentity,
                           mode => active,
                           timeout => maps:get(timeout, Options, 15000)}};
                Error ->
                    close_replicas(DatabaseId, Roots),
                    {stop, Error}
            end;
        {error, _Reason} = Error -> {stop, Error}
    end;
init({_DatabaseId, _Options}) -> {stop, invalid_database_options}.

open_for_init(StorageRoot, DatabaseId, ConfiguredServerIds, ServerIds,
              Options = #{movement := Movement}) ->
    Roots = movement_replica_roots(StorageRoot, ConfiguredServerIds,
                                   ServerIds, Options),
    case maps:get(kind, Movement, move) of
        repair -> ensure_repair_replicas(DatabaseId, Roots,
                                         maps:get(source, Movement));
        move -> ensure_replicas_with_roots(DatabaseId, Roots)
    end;
open_for_init(StorageRoot, DatabaseId, _ConfiguredServerIds, ServerIds,
              Options) ->
    case maps:get(ensure_existing, Options, false) of
        true -> ensure_replicas(StorageRoot, DatabaseId, ServerIds);
        false -> open_replicas(StorageRoot, DatabaseId, ServerIds)
    end.

movement_replica_roots(StorageRoot, ConfiguredServerIds, ServerIds,
                       #{movement := #{replacement := Replacement}}) ->
    OldRoots = replica_roots(StorageRoot, ConfiguredServerIds),
    AllRoots = OldRoots#{Replacement => replacement_root(StorageRoot,
                                                          Replacement)},
    maps:with(ServerIds, AllRoots).

ensure_replicas_with_roots(DatabaseId, Roots) ->
    case ensure_and_open(DatabaseId, maps:to_list(Roots), #{}, undefined, #{}) of
        {ok, Replicas, RuntimeIdentity} ->
            {ok, Replicas, Roots, RuntimeIdentity};
        {error, Reason, CreatedRoots} ->
            close_replicas(DatabaseId, Roots),
            delete_replicas(DatabaseId, CreatedRoots),
            {error, Reason}
    end.

ensure_repair_replicas(DatabaseId, Roots, Failed) ->
    AvailableRoots = maps:remove(Failed, Roots),
    case ensure_replicas_with_roots(DatabaseId, AvailableRoots) of
        {ok, Replicas, _AvailableRoots, RuntimeIdentity} ->
            {ok, Replicas, Roots, RuntimeIdentity};
        Error -> Error
    end.

effective_server_ids(ServerIds,
                     #{movement := #{source := Source,
                                     replacement := Replacement}}) ->
    Candidates = lists:usort([Replacement | ServerIds]),
    case ra:members(Candidates, 5000) of
        {ok, Members, _Leader} ->
            Canonical = lists:sort(Members),
            Old = lists:sort(ServerIds),
            Four = lists:sort(Candidates),
            Final = lists:sort([Replacement | lists:delete(Source, ServerIds)]),
            case Canonical of
                Old -> Old;
                Four -> ServerIds ++ [Replacement];
                Final -> lists:delete(Source, ServerIds) ++ [Replacement];
                _ -> ServerIds
            end;
        _ -> ServerIds
    end;
effective_server_ids(ServerIds, _Options) -> ServerIds.

ensure_raft_cluster(ClusterName, ServerIds, AllowedMembers, RuntimeIdentity) ->
    case ra:members(ServerIds, 5000) of
        {ok, Members, _Leader} ->
            case lists:sort(Members) =:= lists:sort(ServerIds) orelse
                 lists:sort(Members) =:= lists:sort(AllowedMembers) of
                true -> {ok, [], []};
                false -> {error, {raft_membership_mismatch,
                                  lists:sort(ServerIds), lists:sort(Members)}}
            end;
        _ -> erlite_raft_cluster:start(
               ClusterName, ServerIds, RuntimeIdentity)
    end.

handle_call(status, _From, State) ->
    {reply, {ok, database_status(State)}, State};
handle_call(registry_metadata, _From,
            State = #{database_id := DatabaseId, server_ids := ServerIds}) ->
    {reply, {ok, #{database_id => DatabaseId, server_ids => ServerIds}}, State};
handle_call(cool, _From, State = #{mode := cold}) ->
    {reply, ok, State};
handle_call(cool, _From, State = #{database_id := DatabaseId,
                                   replica_roots := Roots}) ->
    ok = close_replicas(DatabaseId, Roots),
    {reply, ok, State#{mode => cold, replicas => #{}}};
handle_call({write, Command, Timeout}, _From, State0) ->
    with_active(State0,
      fun(State = #{server_ids := ServerIds, replicas := Replicas}) ->
              {erlite_raft_database:write(ServerIds, Command, Replicas, Timeout),
               State}
      end);
handle_call({migrate, Command, Timeout}, _From, State0) ->
    with_active(State0,
      fun(State = #{server_ids := ServerIds, replicas := Replicas}) ->
              {erlite_raft_database:write(ServerIds, Command, Replicas, Timeout),
               State}
      end);
handle_call(migration_history, _From, State0) ->
    with_active(State0,
      fun(State = #{server_ids := ServerIds, replicas := Replicas}) ->
              case erlite_raft_cluster:barrier(ServerIds, 15000) of
                  {ok, Barrier, Leader} ->
                      Owner = maps:get(Leader, Replicas),
                      case erlite_raft_applier:catch_up(Leader, Owner, Barrier,
                                                        15000) of
                          {ok, _} -> {erlite_sqlite_owner:migration_history(Owner),
                                      State};
                          Error -> {Error, State}
                      end;
                  Error -> {Error, State}
              end
      end);
handle_call({query, Sql, Params, Timeout}, _From, State0) ->
    with_active(State0,
      fun(State = #{server_ids := ServerIds, replicas := Replicas}) ->
              {erlite_raft_database:consistent_read(
                 ServerIds, Sql, Params, Replicas, Timeout), State}
      end);
handle_call({backup, Generation, BackupRoot}, _From, State0) ->
    with_active(State0,
      fun(State) -> {create_backup(Generation, BackupRoot, State), State} end);
handle_call({add_replacement, Source, Replacement, Generation, Timeout},
            _From, State0) ->
    case activate(State0) of
        {ok, State} ->
            case add_replacement(Source, Replacement, Generation, Timeout,
                                 State) of
                {ok, NewState} -> {reply, ok, NewState};
                {error, _Reason} = Error -> {reply, Error, State}
            end;
        {error, Reason} -> {reply, {error, Reason}, State0}
    end;
handle_call({remove_source, Source, Replacement, Timeout}, _From, State) ->
    case remove_source(Source, Replacement, Timeout, State) of
        {ok, NewState} -> {reply, ok, NewState};
        {error, _Reason} = Error -> {reply, Error, State}
    end;
handle_call(delete, _From, State = #{database_id := DatabaseId,
                                     server_ids := ServerIds,
                                     replica_roots := Roots}) ->
    Reply = case stop_servers(ServerIds) of
                ok ->
                    ok = close_replicas(DatabaseId, Roots),
                    delete_replicas(DatabaseId, Roots);
                Error -> Error
            end,
    {stop, normal, Reply, State}.

handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.

add_replacement(Source, Replacement, Generation, Timeout,
                State = #{database_id := DatabaseId,
                          storage_root := StorageRoot,
                          server_ids := ServerIds,
                          replicas := Replicas,
                          replica_roots := Roots,
                          runtime_identity := RuntimeIdentity}) ->
    case {lists:member(Replacement, ServerIds),
          maps:find(Replacement, Replicas)} of
        {true, {ok, _ReplacementOwner}} ->
            case erlite_raft_database:readiness(
                   ServerIds, Replicas, Replacement, Timeout) of
                {ok, ready, _Index} -> {ok, State};
                Other -> Other
            end;
        _ -> add_new_replacement(Source, Replacement, Generation, Timeout,
                                 DatabaseId, StorageRoot, ServerIds, Replicas,
                                 Roots, RuntimeIdentity, State)
    end.

add_new_replacement(Source, Replacement, Generation, Timeout, DatabaseId,
                    StorageRoot, ServerIds, Replicas, Roots, RuntimeIdentity,
                    State) ->
    case {lists:member(Source, ServerIds), bootstrap_replica(Source, Replicas)} of
        {false, _} -> {error, source_not_in_placement};
        {_, error} -> {error, no_bootstrap_replica_available};
        {true, {ok, BootstrapSource, SourceOwner}} ->
            ReplacementRoot = replacement_root(StorageRoot, Replacement),
            case bootstrap_replacement(ServerIds, BootstrapSource, SourceOwner,
                                       Replacement, ReplacementRoot, DatabaseId,
                                       Generation, RuntimeIdentity, Timeout) of
                {ok, ReplacementOwner} ->
                    {ok, State#{server_ids => lists:usort(
                                             [Replacement | ServerIds]),
                                replicas => Replicas#{Replacement =>
                                                          ReplacementOwner},
                                replica_roots => Roots#{Replacement =>
                                                            ReplacementRoot}}};
                Error -> Error
            end
    end.

bootstrap_replica(Preferred, Replicas) ->
    case maps:find(Preferred, Replicas) of
        {ok, Owner} ->
            case replica_owner_alive(Preferred, Owner) of
                true -> {ok, Preferred, Owner};
                false -> first_live_replica(maps:to_list(Replicas))
            end;
        error -> first_live_replica(maps:to_list(Replicas))
    end.

first_live_replica([]) -> error;
first_live_replica([{ServerId, Owner} | Rest]) ->
    case replica_owner_alive(ServerId, Owner) of
        true -> {ok, ServerId, Owner};
        false -> first_live_replica(Rest)
    end.

replica_owner_alive({_, Node}, Owner) when Node =:= node() ->
    is_process_alive(Owner);
replica_owner_alive({_, Node}, Owner) ->
    case rpc:call(Node, erlang, is_process_alive, [Owner], 2000) of
        true -> true;
        _ -> false
    end.

bootstrap_replacement(ServerIds, Source, SourceOwner, Replacement,
                      ReplacementRoot, DatabaseId, Generation,
                      RuntimeIdentity, Timeout) ->
    case erlite_raft_cluster:barrier(ServerIds, Timeout) of
        {ok, Barrier, _Leader} ->
            case erlite_raft_applier:catch_up(
                   Source, SourceOwner, Barrier, Timeout) of
                {ok, _} ->
                    transfer_bootstrap_snapshot(
                      ServerIds, Source, SourceOwner, Replacement,
                      ReplacementRoot, DatabaseId, Generation,
                      RuntimeIdentity, Barrier, Timeout);
                Other -> Other
            end;
        Other -> Other
    end.

transfer_bootstrap_snapshot(ServerIds, Source, SourceOwner, Replacement,
                            ReplacementRoot, DatabaseId, Generation,
                            RuntimeIdentity, Barrier, Timeout) ->
    SnapshotRoot = filename:join(ReplacementRoot, "movement-source"),
    Index = maps:get(command_index, Barrier),
    Term = maps:get(command_term, Barrier),
    case member_call(Source, erlite_raft_snapshot, create,
                     [SourceOwner, SnapshotRoot, DatabaseId, Generation,
                      Index, Term, 0]) of
        {ok, ManifestPath} ->
            case erlite_raft_snapshot:transfer(
                   Source, Replacement, ManifestPath) of
                {ok, ReceivedManifest} ->
                    install_and_join_replacement(
                      ServerIds, Replacement, ReplacementRoot, DatabaseId,
                      Generation, RuntimeIdentity, ReceivedManifest, Timeout);
                Error -> Error
            end;
        {error, snapshot_exists} ->
            ManifestPath = filename:join(
                             SnapshotRoot,
                             snapshot_manifest_name(DatabaseId, Generation,
                                                    Index)),
            case erlite_raft_snapshot:transfer(
                   Source, Replacement, ManifestPath) of
                {ok, ReceivedManifest} ->
                    install_and_join_replacement(
                      ServerIds, Replacement, ReplacementRoot, DatabaseId,
                      Generation, RuntimeIdentity, ReceivedManifest, Timeout);
                Error -> Error
            end;
        Error -> Error
    end.

install_and_join_replacement(ServerIds, Replacement, ReplacementRoot,
                             DatabaseId, Generation, RuntimeIdentity,
                             ManifestPath, Timeout) ->
    case member_call(Replacement, erlite_raft_snapshot, install,
                     [ReplacementRoot, DatabaseId, Generation, ManifestPath]) of
        {ok, _Index} ->
            case member_call(Replacement, erlite_sqlite_databases, open,
                             [ReplacementRoot, DatabaseId]) of
                {ok, Owner} ->
                    case erlite_sqlite_owner:verify_runtime(
                           Owner, RuntimeIdentity) of
                        ok -> start_and_verify_replacement(
                                DatabaseId, ServerIds, Replacement, Owner,
                                RuntimeIdentity, Timeout);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

start_and_verify_replacement(DatabaseId, ServerIds, Replacement, Owner,
                             RuntimeIdentity, Timeout) ->
    ClusterName = cluster_name(DatabaseId),
    Machine = {module, erlite_raft_machine,
               #{runtime_identity => RuntimeIdentity}},
    Members = lists:usort([Replacement | ServerIds]),
    case member_call(Replacement, ra, start_server,
                     [default, ClusterName, Replacement, Machine, Members]) of
        ok -> add_and_catch_up(ServerIds, Replacement, Owner, Timeout);
        {error, already_started} ->
            add_and_catch_up(ServerIds, Replacement, Owner, Timeout);
        {error, {already_started, _Pid}} ->
            add_and_catch_up(ServerIds, Replacement, Owner, Timeout);
        Error -> Error
    end.

add_and_catch_up(ServerIds, Replacement, Owner, Timeout) ->
    case ensure_member(ServerIds, Replacement, Timeout) of
        ok ->
            Replicas = #{Replacement => Owner},
            case erlite_raft_database:readiness(
                   ServerIds, Replicas, Replacement, Timeout) of
                {ok, ready, _Index} -> ok_result(Owner);
                Other -> rollback_unready_replacement(
                           ServerIds, Replacement, Other, Timeout)
            end;
        Error -> Error
    end.

rollback_unready_replacement(ServerIds, Replacement, ReadinessError, Timeout) ->
    case ra:remove_member(ServerIds, Replacement, Timeout) of
        {ok, _Reply, _Leader} -> ReadinessError;
        {error, not_member} -> ReadinessError;
        RollbackError ->
            {error, {replacement_readiness_failed_and_rollback_failed,
                     ReadinessError, RollbackError}}
    end.

ok_result(Owner) -> {ok, Owner}.

create_backup(Generation, BackupRoot,
              #{database_id := DatabaseId, server_ids := ServerIds,
                replicas := Replicas, timeout := Timeout}) ->
    case erlite_raft_cluster:barrier(ServerIds, Timeout) of
        {ok, Barrier, Leader} ->
            case bootstrap_replica(Leader, Replicas) of
                {ok, Source, Owner} ->
                    case erlite_raft_applier:catch_up(Source, Owner, Barrier,
                                                     Timeout) of
                        {ok, _} ->
                            Index = maps:get(command_index, Barrier),
                            Term = maps:get(command_term, Barrier),
                            case member_call(
                                   Source, erlite_raft_snapshot, create,
                                   [Owner, BackupRoot, DatabaseId, Generation,
                                    Index, Term, 0]) of
                                {ok, ManifestPath} ->
                                    case member_call(
                                           Source, erlite_raft_snapshot,
                                           verify,
                                           [ManifestPath, DatabaseId,
                                            Generation, Index]) of
                                        {ok, Manifest, _} ->
                                            {ok, Source, ManifestPath, Manifest};
                                        Error -> Error
                                    end;
                                {error, snapshot_exists} ->
                                    ManifestPath = filename:join(
                                      BackupRoot,
                                      snapshot_manifest_name(DatabaseId,
                                                             Generation,
                                                             Index)),
                                    case member_call(
                                           Source, erlite_raft_snapshot,
                                           verify,
                                           [ManifestPath, DatabaseId,
                                            Generation, Index]) of
                                        {ok, Manifest, _} ->
                                            {ok, Source, ManifestPath, Manifest};
                                        Error -> Error
                                    end;
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                error -> {error, no_backup_replica_available}
            end;
        Error -> Error
    end.

ensure_member(ServerIds, Replacement, Timeout) ->
    case ra:members(ServerIds, Timeout) of
        {ok, Members, _Leader} ->
            case lists:member(Replacement, Members) of
                true -> ok;
                false ->
                    case ra:add_member(ServerIds, Replacement, Timeout) of
                        {ok, _Reply, _} -> ok;
                        {error, already_member} -> ok;
                        Other -> Other
                    end
            end;
        Other -> Other
    end.

remove_source(Source, Replacement, Timeout,
              State = #{database_id := DatabaseId,
                        server_ids := ServerIds,
                        replicas := Replicas,
                        replica_roots := Roots}) ->
    case {lists:member(Source, ServerIds), lists:member(Replacement, ServerIds)} of
        {false, true} -> {ok, State};
        {true, true} ->
            Remaining = lists:delete(Source, ServerIds),
            case ensure_source_removed(Remaining, Source, Timeout) of
                ok -> retire_source(DatabaseId, Source, Replacement,
                                    Remaining, Replicas, Roots, State);
                Error -> Error
            end;
        _ -> {error, replacement_not_added}
    end.

ensure_source_removed(Remaining, Source, Timeout) ->
    case ra:members(Remaining, Timeout) of
        {ok, Members, _Leader} ->
            case lists:member(Source, Members) of
                false -> best_effort_force_delete(Source);
                true ->
                    case ra:remove_member(Remaining, Source, Timeout) of
                        {ok, _Reply, _} ->
                            verify_source_removed(Remaining, Source, Timeout);
                        {error, not_member} ->
                            verify_source_removed(Remaining, Source, Timeout);
                        Error -> Error
                    end
            end;
        Other -> Other
    end.

verify_source_removed(Remaining, Source, Timeout) ->
    case ra:members(Remaining, Timeout) of
        {ok, Members, _Leader} ->
            case lists:member(Source, Members) of
                false -> best_effort_force_delete(Source);
                true -> {error, source_still_in_membership}
            end;
        Error -> Error
    end.

best_effort_force_delete(Source) ->
    _ = benign_force_delete(Source),
    ok.

benign_force_delete(Source) ->
    case member_call(Source, ra, force_delete_server, [default, Source]) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, noproc} -> ok;
        Error -> Error
    end.

retire_source(DatabaseId, Source, _Replacement, Remaining, Replicas, Roots,
              State) ->
    SourceRoot = maps:get(Source, Roots),
    _ = member_call(Source, erlite_sqlite_databases, close,
                    [SourceRoot, DatabaseId]),
    _ = member_call(Source, erlite_sqlite_databases, delete,
                    [SourceRoot, DatabaseId]),
    {ok, State#{server_ids => lists:sort(Remaining),
                replicas => maps:remove(Source, Replicas),
                replica_roots => maps:remove(Source, Roots)}}.

replacement_root(StorageRoot, Replacement) ->
    Digest = binary:encode_hex(
               crypto:hash(sha256, term_to_binary(Replacement)), lowercase),
    filename:join([StorageRoot, "replicas", "movement",
                   binary_to_list(Digest)]).

snapshot_manifest_name(DatabaseId, Generation, Index) ->
    Digest = erlite_sqlite_database:digest(DatabaseId),
    binary_to_list(Digest) ++ "-" ++ integer_to_list(Generation) ++ "-" ++
        integer_to_list(Index) ++ ".manifest".


with_active(State0, Operation) ->
    case activate(State0) of
        {ok, State} ->
            {Reply, NewState} = Operation(State),
            {reply, Reply, NewState};
        {error, Reason} -> {reply, {error, Reason}, State0}
    end.

activate(State = #{mode := active}) -> {ok, State};
activate(State = #{database_id := DatabaseId,
                   replica_roots := Roots,
                   runtime_identity := Expected}) ->
    case reopen_replicas(DatabaseId, maps:to_list(Roots), Expected, #{}) of
        {ok, Replicas} -> {ok, State#{mode => active, replicas => Replicas}};
        {error, _Reason} = Error -> Error
    end.

open_replicas(StorageRoot, DatabaseId, ServerIds) ->
    Roots = replica_roots(StorageRoot, ServerIds),
    case create_and_open(DatabaseId, maps:to_list(Roots), #{}, undefined, #{}) of
        {ok, Replicas, RuntimeIdentity} ->
            {ok, Replicas, Roots, RuntimeIdentity};
        {error, Reason, CreatedRoots} ->
            close_replicas(DatabaseId, CreatedRoots),
            delete_replicas(DatabaseId, CreatedRoots),
            {error, Reason}
    end.

ensure_replicas(StorageRoot, DatabaseId, ServerIds) ->
    Roots = replica_roots(StorageRoot, ServerIds),
    case ensure_and_open(DatabaseId, maps:to_list(Roots), #{}, undefined, #{}) of
        {ok, Replicas, RuntimeIdentity} ->
            {ok, Replicas, Roots, RuntimeIdentity};
        {error, Reason, CreatedRoots} ->
            close_replicas(DatabaseId, Roots),
            delete_replicas(DatabaseId, CreatedRoots),
            {error, Reason}
    end.

replica_roots(StorageRoot, ServerIds) ->
    maps:from_list(
      [{ServerId, replica_root(StorageRoot, ServerId, N)}
       || {ServerId, N} <- lists:zip(ServerIds, [1, 2, 3])]).

replica_root(StorageRoot, {Name, _Node} = ServerId, Fallback) ->
    NameString = atom_to_list(Name),
    case re:run(NameString, "_r([123])$", [{capture, [1], list}]) of
        {match, [Ordinal]} ->
            filename:join([StorageRoot, "replicas", Ordinal]);
        nomatch ->
            case lists:suffix("_replacement", NameString) of
                true -> replacement_root(StorageRoot, ServerId);
                false -> filename:join(
                           [StorageRoot, "replicas",
                            integer_to_list(Fallback)])
            end
    end.

ensure_and_open(_DatabaseId, [], Replicas, RuntimeIdentity, _CreatedRoots) ->
    {ok, Replicas, RuntimeIdentity};
ensure_and_open(DatabaseId, [{ServerId, Root} | Rest], Replicas, Expected,
                CreatedRoots) ->
    case member_call(ServerId, erlite_sqlite_databases, create,
                     [Root, DatabaseId]) of
        ok ->
            ensure_opened(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
                          CreatedRoots#{ServerId => Root});
        {error, database_exists} ->
            ensure_opened(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
                          CreatedRoots);
        {error, Reason} -> {error, Reason, CreatedRoots}
    end.

ensure_opened(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
              CreatedRoots) ->
    case member_call(ServerId, erlite_sqlite_databases, open,
                     [Root, DatabaseId]) of
        {ok, Owner} ->
            case erlite_sqlite_owner:runtime_identity(Owner) of
                {ok, Identity} when Expected =:= undefined; Identity =:= Expected ->
                    ensure_and_open(DatabaseId, Rest,
                                    Replicas#{ServerId => Owner}, Identity,
                                    CreatedRoots);
                {ok, _Different} ->
                    {error, incompatible_sqlite_runtime, CreatedRoots};
                {error, Reason} -> {error, Reason, CreatedRoots}
            end;
        {error, Reason} -> {error, Reason, CreatedRoots}
    end.

create_and_open(_DatabaseId, [], Replicas, RuntimeIdentity, _CreatedRoots) ->
    {ok, Replicas, RuntimeIdentity};
create_and_open(DatabaseId, [{ServerId, Root} | Rest], Replicas, Expected,
                CreatedRoots) ->
    case member_call(ServerId, erlite_sqlite_databases, create,
                     [Root, DatabaseId]) of
        ok ->
            NewCreated = CreatedRoots#{ServerId => Root},
            open_created(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
                         NewCreated);
        {error, database_exists} -> {error, database_exists, CreatedRoots};
        {error, Reason} -> {error, Reason, CreatedRoots}
    end.

open_created(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
             CreatedRoots) ->
    case member_call(ServerId, erlite_sqlite_databases, open,
                     [Root, DatabaseId]) of
        {ok, Owner} ->
            case erlite_sqlite_owner:runtime_identity(Owner) of
                {ok, Identity} when Expected =:= undefined; Identity =:= Expected ->
                    create_and_open(DatabaseId, Rest,
                                    Replicas#{ServerId => Owner}, Identity,
                                    CreatedRoots);
                {ok, _Different} ->
                    {error, incompatible_sqlite_runtime, CreatedRoots};
                {error, Reason} -> {error, Reason, CreatedRoots}
            end;
        {error, Reason} -> {error, Reason, CreatedRoots}
    end.

reopen_replicas(_DatabaseId, [], _Expected, Replicas) -> {ok, Replicas};
reopen_replicas(DatabaseId, [{ServerId, Root} | Rest], Expected, Replicas) ->
    case member_call(ServerId, erlite_sqlite_databases, open, [Root, DatabaseId]) of
        {ok, Owner} ->
            case erlite_sqlite_owner:verify_runtime(Owner, Expected) of
                ok -> reopen_replicas(DatabaseId, Rest, Expected,
                                      Replicas#{ServerId => Owner});
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

database_status(#{database_id := DatabaseId, mode := Mode,
                  server_ids := ServerIds, replicas := Replicas,
                  replica_roots := Roots}) ->
    #{database_id => DatabaseId, mode => Mode,
      raft_members => length(ServerIds),
      open_sqlite_replicas => map_size(Replicas),
      controller_memory_bytes => process_memory(node(), self()),
      sqlite_owner_memory_bytes => lists:sum(
                                     [process_memory(
                                        element(2, ServerId), Owner)
                                      || {ServerId, Owner} <-
                                             maps:to_list(Replicas)]),
      raft_server_memory_bytes => lists:sum(
                                    [raft_server_memory(ServerId)
                                     || ServerId <- ServerIds]),
      sqlite_bytes => lists:sum(
                        [file_size(ServerId, Root, DatabaseId)
                         || {ServerId, Root} <- maps:to_list(Roots)])}.

file_size(ServerId, Root, DatabaseId) ->
    case member_call(ServerId, erlite_sqlite_database, path, [Root, DatabaseId]) of
        {ok, Path} ->
            case member_call(ServerId, filelib, file_size, [Path]) of
                Size when is_integer(Size) -> Size;
                _ -> 0
            end;
        _ -> 0
    end.

raft_server_memory({Name, Node}) ->
    case member_call({Name, Node}, ra_directory, where_is, [default, Name]) of
        Pid when is_pid(Pid) -> process_memory(Node, Pid);
        _ -> 0
    end.

process_memory(Node, Pid) when Node =:= node() ->
    case process_info(Pid, memory) of
        {memory, Bytes} -> Bytes;
        undefined -> 0
    end;
process_memory(Node, Pid) ->
    case rpc:call(Node, erlang, process_info, [Pid, memory]) of
        {memory, Bytes} -> Bytes;
        _ -> 0
    end.

close_replicas(DatabaseId, Roots) ->
    lists:foreach(fun({ServerId, Root}) ->
                          _ = member_call(ServerId, erlite_sqlite_databases,
                                          close, [Root, DatabaseId])
                  end, maps:to_list(Roots)),
    ok.

delete_replicas(DatabaseId, Roots) ->
    Results = [member_call(ServerId, erlite_sqlite_databases, delete,
                           [Root, DatabaseId])
               || {ServerId, Root} <- maps:to_list(Roots)],
    case [Error || Error = {error, _} <- Results] of
        [] -> ok;
        [Error | _] -> Error
    end.

stop_servers(ServerIds) ->
    Results = [member_call(ServerId, ra, force_delete_server,
                           [default, ServerId]) || ServerId <- ServerIds],
    case [Error || Error <- Results, not benign_delete_result(Error)] of
        [] -> ok;
        [Error | _] -> Error
    end.

benign_delete_result(ok) -> true;
benign_delete_result({error, not_found}) -> true;
benign_delete_result(_) -> false.

member_call({_, Node}, Module, Function, Arguments) when Node =:= node() ->
    erlang:apply(Module, Function, Arguments);
member_call({_, Node}, Module, Function, Arguments) ->
    case rpc:call(Node, Module, Function, Arguments, ?RPC_TIMEOUT) of
        {badrpc, Reason} -> {error, {replica_rpc_failed, Node, Reason}};
        Result -> Result
    end.

cluster_name(DatabaseId) ->
    <<"erlite-db-", (erlite_sqlite_database:digest(DatabaseId))/binary>>.
