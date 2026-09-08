-module(erlite_catalog_machine).
-behaviour(ra_machine).

-export([init/1, apply/3, status/1, database/2, recoverable/1]).

-type node_record() :: #{node_id := binary(),
                         node_name := binary(),
                         server_id := {atom(), node()},
                         state := joining | active | leaving}.
-type state() :: #{cluster_id := binary(),
                   cluster_name := binary(),
                   replication_factor := 3,
                   quorum := 2,
                   nodes := #{binary() := node_record()},
                   databases := map()}.

-spec init(map()) -> state().
init(#{cluster_id := ClusterId, cluster_name := ClusterName,
       nodes := Nodes}) ->
    #{cluster_id => ClusterId,
      cluster_name => ClusterName,
      replication_factor => 3,
      quorum => 2,
      nodes => maps:from_list([{maps:get(node_id, Node), Node} || Node <- Nodes]),
      databases => #{}}.

-spec apply(map(), term(), state()) -> {state(), term()}.
apply(_Meta, {prepare_join, Node0}, State = #{nodes := Nodes}) ->
    case valid_join_node(Node0) of
        true ->
            Node = Node0#{state => joining},
            NodeId = maps:get(node_id, Node),
            case maps:get(NodeId, Nodes, undefined) of
                Existing when is_map(Existing) ->
                    case same_identity(Existing, Node) of
                        true -> {State, ok};
                        false -> {State, {error, duplicate_node_id}}
                    end;
                undefined -> prepare_unique_join(Node, State);
                _Other -> {State, {error, duplicate_node_id}}
            end;
        false -> {State, {error, invalid_node}}
    end;
apply(_Meta, {activate_node, NodeId}, State = #{nodes := Nodes}) ->
    case maps:get(NodeId, Nodes, undefined) of
        #{state := active} -> {State, ok};
        Node = #{state := joining} ->
            {State#{nodes => Nodes#{NodeId => Node#{state => active}}}, ok};
        undefined -> {State, {error, node_not_found}};
        #{state := leaving} -> {State, {error, node_is_leaving}}
    end;
apply(_Meta, {prepare_leave, NodeId}, State = #{nodes := Nodes}) ->
    case maps:get(NodeId, Nodes, undefined) of
        Node = #{state := active} ->
            {State#{nodes => Nodes#{NodeId => Node#{state => leaving}}}, ok};
        #{state := leaving} -> {State, ok};
        undefined -> {State, {error, node_not_found}};
        #{state := joining} -> {State, {error, node_is_joining}}
    end;
apply(_Meta, {finalize_leave, NodeId}, State = #{nodes := Nodes}) ->
    case maps:get(NodeId, Nodes, undefined) of
        #{state := leaving} -> {State#{nodes => maps:remove(NodeId, Nodes)}, ok};
        undefined -> {State, ok};
        _Node -> {State, {error, node_not_leaving}}
    end;
apply(_Meta, {prepare_database_create, DatabaseId, OperationId, Generation,
              Replicas}, State) ->
    prepare_database_create(DatabaseId, OperationId, Generation, Replicas,
                            State);
apply(_Meta, {mark_database_ready, DatabaseId, OperationId, Generation}, State) ->
    transition_database(DatabaseId, OperationId, Generation, creating, ready,
                        State);
apply(_Meta, {prepare_database_delete, DatabaseId, OperationId, Generation},
      State) ->
    prepare_database_delete(DatabaseId, OperationId, Generation, State);
apply(_Meta, {tombstone_database, DatabaseId, OperationId, Generation}, State) ->
    transition_database(DatabaseId, OperationId, Generation, deleting,
                        tombstoned, State);
apply(_Meta, {prepare_database_move, DatabaseId, OperationId, Generation,
              Source, Replacement}, State) ->
    prepare_database_move(DatabaseId, OperationId, Generation, Source,
                          Replacement, State);
apply(_Meta, {mark_database_replacement_ready, DatabaseId, OperationId,
              Generation}, State) ->
    transition_database_move(DatabaseId, OperationId, Generation,
                             adding, removing, State);
apply(_Meta, {finish_database_move, DatabaseId, OperationId, Generation}, State) ->
    finish_database_move(DatabaseId, OperationId, Generation, State);
apply(_Meta, {prepare_database_restore, DatabaseId, OperationId,
              ExpectedGeneration, NewGeneration, Replicas, Backup, Mode},
      State) ->
    prepare_database_restore(DatabaseId, OperationId, ExpectedGeneration,
                             NewGeneration, Replicas, Backup, Mode, State);
apply(_Meta, {finish_database_restore, DatabaseId, OperationId, Generation},
      State) ->
    finish_database_restore(DatabaseId, OperationId, Generation, State);
apply(_Meta, {mark_database_under_replicated, DatabaseId, OperationId,
              Generation, Failed, DetectedAt}, State) ->
    mark_database_under_replicated(DatabaseId, OperationId, Generation, Failed,
                                   DetectedAt, State);
apply(_Meta, {clear_database_under_replicated, DatabaseId, OperationId,
              Generation}, State) ->
    clear_database_under_replicated(DatabaseId, OperationId, Generation, State);
apply(_Meta, {prepare_database_repair, DatabaseId, OperationId, Generation,
              Failed, Replacement}, State) ->
    prepare_database_repair(DatabaseId, OperationId, Generation, Failed,
                            Replacement, State);
apply(_Meta, {clear_stale_replica, DatabaseId, ServerId, Generation}, State) ->
    clear_stale_replica(DatabaseId, ServerId, Generation, State);
apply(_Meta, Command, State) ->
    {State, {error, {unsupported_catalog_command, Command}}}.

prepare_unique_join(Node, State = #{nodes := Nodes}) ->
    NodeName = maps:get(node_name, Node),
    ServerId = maps:get(server_id, Node),
    Existing = maps:values(Nodes),
    case {lists:any(fun(N) -> maps:get(node_name, N) =:= NodeName end, Existing),
          lists:any(fun(N) -> maps:get(server_id, N) =:= ServerId end, Existing)} of
        {true, _} -> {State, {error, duplicate_node_name}};
        {_, true} -> {State, {error, duplicate_catalog_server_id}};
        {false, false} ->
            NodeId = maps:get(node_id, Node),
            {State#{nodes => Nodes#{NodeId => Node}}, ok}
    end.

valid_join_node(#{node_id := NodeId, node_name := NodeName,
                  server_id := {ServerName, ErlangNode}})
  when is_binary(NodeId), byte_size(NodeId) =:= 16,
       is_binary(NodeName), byte_size(NodeName) > 0,
       is_atom(ServerName), is_atom(ErlangNode) -> true;
valid_join_node(_) -> false.

same_identity(Left, Right) ->
    lists:all(fun(Key) -> maps:get(Key, Left) =:= maps:get(Key, Right) end,
              [node_id, node_name, server_id]).

prepare_database_create(DatabaseId, OperationId, Generation, Replicas,
                        State = #{nodes := Nodes}) ->
    Databases = maps:get(databases, State, #{}),
    case valid_database_operation(DatabaseId, OperationId, Generation,
                                  Replicas) of
        false -> {State, {error, invalid_database_operation}};
        true ->
            CanonicalReplicas = lists:sort(Replicas),
            case placement_available(DatabaseId, CanonicalReplicas,
                                     Databases, Nodes) of
                false -> {State, {error, invalid_or_conflicting_placement}};
                true ->
                    case maps:get(DatabaseId, Databases, undefined) of
                        undefined when Generation =:= 1 ->
                            put_database(new_database(DatabaseId, OperationId,
                                                      Generation,
                                                      CanonicalReplicas),
                                         State);
                        undefined ->
                            {State, {error, {expected_generation, 1}}};
                        Existing ->
                            resume_or_recreate(Existing, OperationId,
                                               Generation, CanonicalReplicas,
                                               State)
                    end
            end
    end.

resume_or_recreate(#{operation_id := OperationId, generation := Generation,
                     replicas := Replicas, state := Lifecycle},
                   OperationId, Generation, Replicas, State)
  when Lifecycle =:= creating; Lifecycle =:= ready -> {State, ok};
resume_or_recreate(#{database_id := DatabaseId, state := tombstoned,
                     generation := Previous}, OperationId, Generation,
                   Replicas, State)
  when Generation =:= Previous + 1 ->
    put_database(new_database(DatabaseId, OperationId, Generation, Replicas),
                 State);
resume_or_recreate(Existing, _OperationId, Generation, _Replicas, State) ->
    {State, fence_error(Existing, Generation)}.

prepare_database_delete(DatabaseId, OperationId, Generation,
                        State) ->
    Databases = maps:get(databases, State, #{}),
    case valid_identity(DatabaseId, OperationId, Generation) of
        false -> {State, {error, invalid_database_operation}};
        true ->
            case maps:get(DatabaseId, Databases, undefined) of
                undefined -> {State, {error, database_not_found}};
                #{generation := Generation, state := ready,
                  movement := #{operation_id := MoveOperation}} ->
                    {State, {error, {movement_in_progress, MoveOperation}}};
                Existing = #{generation := Generation, state := ready} ->
                    put_database(Existing#{state => deleting,
                                           operation_id => OperationId}, State);
                #{generation := Generation, state := deleting,
                  operation_id := OperationId} -> {State, ok};
                #{generation := Generation, state := tombstoned,
                  operation_id := OperationId} -> {State, ok};
                #{generation := Generation, state := creating} ->
                    {State, {error, {invalid_lifecycle_transition,
                                     creating, deleting}}};
                Existing -> {State, fence_error(Existing, Generation)}
            end
    end.

transition_database(DatabaseId, OperationId, Generation, From, To,
                    State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{operation_id := OperationId, generation := Generation,
                     state := From} -> put_database(Existing#{state => To}, State);
        #{operation_id := OperationId, generation := Generation, state := To} ->
            {State, ok};
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, fence_error(Existing, Generation)}
    end.

new_database(DatabaseId, OperationId, Generation, Replicas) ->
    #{database_id => DatabaseId, state => creating,
      operation_id => OperationId, generation => Generation,
      replicas => lists:sort(Replicas), replication_factor => 3,
      schema_version => 0}.

prepare_database_restore(DatabaseId, OperationId, ExpectedGeneration,
                         NewGeneration, Replicas, Backup, Mode,
                         State = #{nodes := Nodes}) ->
    Databases = maps:get(databases, State, #{}),
    Canonical = lists:sort(Replicas),
    case valid_backup(Backup) of
        false -> {State, {error, invalid_database_restore}};
        true ->
            case Mode =:= replace andalso
                 maps:get(database_id, Backup) =/= DatabaseId of
                true -> {State, {error, backup_database_mismatch}};
                false ->
                    prepare_valid_database_restore(
                      DatabaseId, OperationId, ExpectedGeneration,
                      NewGeneration, Canonical, Backup, Mode, Databases, Nodes,
                      State)
            end
    end.

prepare_valid_database_restore(DatabaseId, OperationId, ExpectedGeneration,
                               NewGeneration, Replicas, Backup, Mode,
                               Databases, Nodes, State) ->
    Valid = valid_database_operation(DatabaseId, OperationId, NewGeneration,
                                     Replicas) andalso
        ((Mode =:= replace andalso NewGeneration =:= ExpectedGeneration + 1)
         orelse (Mode =:= clone andalso ExpectedGeneration =:= 0 andalso
                 NewGeneration =:= 1)),
    case Valid andalso placement_available(DatabaseId, Replicas, Databases,
                                            Nodes) of
        false -> {State, {error, invalid_database_restore}};
        true -> prepare_database_restore_record(
                  maps:get(DatabaseId, Databases, undefined), DatabaseId,
                  OperationId, ExpectedGeneration, NewGeneration, Replicas,
                  Backup, Mode, State)
    end.

prepare_database_restore_record(
  #{state := restoring, operation_id := OperationId,
    generation := NewGeneration, replicas := Replicas,
    restore := #{backup := Backup, mode := Mode}}, _DatabaseId, OperationId,
  _Expected, NewGeneration, Replicas, Backup, Mode, State) ->
    {State, ok};
prepare_database_restore_record(undefined, DatabaseId, OperationId, 0, 1,
                                Replicas, Backup, clone, State) ->
    put_database(#{database_id => DatabaseId, state => restoring,
                   operation_id => OperationId, generation => 1,
                   replicas => Replicas, replication_factor => 3,
                   schema_version => maps:get(schema_version, Backup),
                   restore => #{mode => clone, backup => Backup}}, State);
prepare_database_restore_record(
  Existing = #{state := ready, generation := ExpectedGeneration,
               replicas := OldReplicas}, _DatabaseId, OperationId,
  ExpectedGeneration, NewGeneration, Replicas, Backup, replace, State) ->
    case maps:is_key(movement, Existing) orelse maps:is_key(repair, Existing) of
        true -> {State, {error, database_operation_in_progress}};
        false ->
            Restoring = Existing#{state => restoring,
                                  operation_id => OperationId,
                                  generation => NewGeneration,
                                  replicas => Replicas,
                                  schema_version => maps:get(schema_version,
                                                             Backup),
                                  restore => #{mode => replace,
                                               backup => Backup,
                                               previous_generation =>
                                                   ExpectedGeneration,
                                               previous_replicas =>
                                                   OldReplicas}},
            put_database(Restoring, State)
    end;
prepare_database_restore_record(undefined, _DatabaseId, _OperationId,
                                _Expected, _New, _Replicas, _Backup, replace,
                                State) ->
    {State, {error, database_not_found}};
prepare_database_restore_record(Existing, _DatabaseId, _OperationId,
                                Expected, _New, _Replicas, _Backup, _Mode,
                                State) ->
    {State, fence_error(Existing, Expected)}.

valid_backup(#{database_id := Id, generation := Generation,
               raft_index := Index, raft_term := Term,
               schema_version := SchemaVersion, created_at := CreatedAt,
               sha256 := Digest, manifest_path := Path,
               source_server := Source}) ->
    is_binary(Id) andalso byte_size(Id) > 0 andalso
        is_integer(Generation) andalso Generation > 0 andalso
        is_integer(Index) andalso Index >= 0 andalso
        is_integer(Term) andalso Term >= 0 andalso
        is_integer(SchemaVersion) andalso SchemaVersion >= 0 andalso
        is_integer(CreatedAt) andalso CreatedAt > 0 andalso
        is_binary(Digest) andalso byte_size(Digest) =:= 32 andalso
        is_list(Path) andalso Path =/= [] andalso valid_server_id(Source);
valid_backup(_) -> false.

finish_database_restore(DatabaseId, OperationId, Generation, State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{state := restoring, operation_id := OperationId,
                     generation := Generation} ->
            Ready0 = maps:remove(restore, Existing#{state => ready}),
            put_database(Ready0#{last_restore =>
                                  #{operation_id => OperationId,
                                    generation => Generation}}, State);
        #{state := ready, generation := Generation,
          last_restore := #{operation_id := OperationId}} -> {State, ok};
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, fence_error(Existing, Generation)}
    end.

prepare_database_move(DatabaseId, OperationId, Generation, Source, Replacement,
                      State) ->
    Databases = maps:get(databases, State, #{}),
    case valid_identity(DatabaseId, OperationId, Generation) andalso
         valid_server_id(Source) andalso valid_server_id(Replacement) andalso
         Source =/= Replacement of
        false -> {State, {error, invalid_database_move}};
        true ->
            case maps:get(DatabaseId, Databases, undefined) of
                Existing = #{state := ready, generation := Generation,
                             replicas := Replicas} ->
                    prepare_database_move_for_record(
                      Existing, OperationId, Source, Replacement, Replicas,
                      Databases, maps:get(nodes, State), State);
                undefined -> {State, {error, database_not_found}};
                Existing -> {State, fence_error(Existing, Generation)}
            end
    end.

prepare_database_move_for_record(
  #{repair := #{operation_id := Current}}, _OperationId, _Source,
  _Replacement, _Replicas, _Databases, _Nodes, State) ->
    {State, {error, {repair_in_progress, Current}}};
prepare_database_move_for_record(
  #{movement := #{operation_id := OperationId, source := Source,
                  replacement := Replacement}},
  OperationId, Source, Replacement, _Replicas, _Databases, _Nodes, State) ->
    {State, ok};
prepare_database_move_for_record(#{movement := #{operation_id := Current}},
                                 _OperationId, _Source, _Replacement, _Replicas,
                                 _Databases, _Nodes, State) ->
    {State, {error, {movement_in_progress, Current}}};
prepare_database_move_for_record(Existing, OperationId, Source, Replacement,
                                 Replicas, Databases, Nodes, State) ->
    case lists:member(Source, Replicas) of
        false -> {State, {error, source_not_in_placement}};
        true ->
            case lists:member(Replacement, Replicas) of
                true -> {State, {error, replacement_already_in_placement}};
                false ->
                    case replacement_available(Replacement, Databases, Nodes) of
                        true ->
                            Movement = #{operation_id => OperationId,
                                         source => Source,
                                         replacement => Replacement,
                                         phase => adding},
                            put_database(Existing#{movement => Movement}, State);
                        false -> {State, {error, replacement_unavailable}}
                    end
            end
    end.

transition_database_move(DatabaseId, OperationId, Generation, From, To, State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{state := ready, generation := Generation,
                     movement := Movement = #{operation_id := OperationId,
                                               phase := From}} ->
            put_database(Existing#{movement => Movement#{phase => To}}, State);
        #{state := ready, generation := Generation,
          movement := #{operation_id := OperationId, phase := To}} ->
            {State, ok};
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, move_fence_error(Existing, OperationId, Generation)}
    end.

finish_database_move(DatabaseId, OperationId, Generation, State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{state := ready, generation := Generation,
                     replicas := Replicas,
                     movement := #{operation_id := OperationId,
                                   source := Source, replacement := Replacement,
                                   phase := removing}} ->
            NewReplicas = lists:sort([Replacement | lists:delete(Source, Replicas)]),
            Completed = #{operation_id => OperationId, source => Source,
                          replacement => Replacement,
                          from_generation => Generation},
            Stale = #{server_id => Source, generation => Generation},
            ExistingStale = maps:get(stale_replicas, Existing, []),
            Finished = maps:remove(
                         repair,
                         Existing#{replicas => NewReplicas,
                                   generation => Generation + 1,
                                   last_movement => Completed,
                                   stale_replicas =>
                                       lists:usort([Stale | ExistingStale])}),
            put_database(maps:remove(movement, Finished), State);
        #{state := ready, generation := CompletedGeneration,
          last_movement := #{operation_id := OperationId,
                             from_generation := Generation}}
          when CompletedGeneration =:= Generation + 1 -> {State, ok};
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, move_fence_error(Existing, OperationId, Generation)}
    end.

move_fence_error(#{generation := Current}, _OperationId, Supplied)
  when Supplied =/= Current -> {error, {stale_generation, Supplied, Current}};
move_fence_error(#{movement := #{operation_id := Current}}, OperationId, _)
  when OperationId =/= Current -> {error, {operation_id_conflict, Current}};
move_fence_error(#{movement := #{phase := Phase}}, _OperationId, _) ->
    {error, {invalid_movement_transition, Phase}};
move_fence_error(_Existing, _OperationId, _) -> {error, no_movement_in_progress}.

mark_database_under_replicated(DatabaseId, OperationId, Generation, Failed,
                               DetectedAt, State) ->
    Databases = maps:get(databases, State, #{}),
    Valid = valid_identity(DatabaseId, OperationId, Generation) andalso
        valid_server_id(Failed) andalso is_integer(DetectedAt) andalso
        DetectedAt >= 0,
    case {Valid, maps:get(DatabaseId, Databases, undefined)} of
        {false, _} -> {State, {error, invalid_database_repair}};
        {true, Existing = #{state := ready, generation := Generation,
                            replicas := Replicas}} ->
            case {maps:find(movement, Existing), lists:member(Failed, Replicas),
                  maps:find(repair, Existing)} of
                {{ok, #{operation_id := Current}}, _, _} ->
                    {State, {error, {movement_in_progress, Current}}};
                {error, false, _} -> {State, {error, failed_not_in_placement}};
                {error, true, {ok, #{failed := Failed}}} -> {State, ok};
                {error, true, {ok, #{operation_id := Current}}} ->
                    {State, {error, {repair_in_progress, Current}}};
                {error, true, error} ->
                    Repair = #{operation_id => OperationId, failed => Failed,
                               detected_at => DetectedAt, phase => waiting},
                    put_database(Existing#{repair => Repair}, State)
            end;
        {true, undefined} -> {State, {error, database_not_found}};
        {true, Existing} -> {State, fence_error(Existing, Generation)}
    end.

clear_database_under_replicated(DatabaseId, OperationId, Generation, State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{state := ready, generation := Generation,
                     repair := #{operation_id := OperationId,
                                 phase := waiting}} ->
            put_database(maps:remove(repair, Existing), State);
        Existing = #{state := ready, generation := Generation} ->
            case maps:is_key(repair, Existing) of
                false -> {State, ok};
                true -> {State, {error, repair_already_started}}
            end;
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, fence_error(Existing, Generation)}
    end.

prepare_database_repair(DatabaseId, OperationId, Generation, Failed,
                        Replacement, State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{state := ready, generation := Generation,
                     repair := #{operation_id := OperationId,
                                 failed := Failed, phase := waiting}} ->
            case replacement_available(Replacement, Databases,
                                       maps:get(nodes, State)) of
                true ->
                    Movement = #{operation_id => OperationId, source => Failed,
                                 replacement => Replacement, phase => adding,
                                 kind => repair},
                    put_database(Existing#{movement => Movement,
                                           repair =>
                                               (maps:get(repair, Existing))#{
                                                 phase => repairing}}, State);
                false -> {State, {error, replacement_unavailable}}
            end;
        #{state := ready, generation := Generation,
          movement := #{operation_id := OperationId, source := Failed,
                        replacement := Replacement, kind := repair}} ->
            {State, ok};
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, move_fence_error(Existing, OperationId, Generation)}
    end.

clear_stale_replica(DatabaseId, ServerId, Generation, State) ->
    Databases = maps:get(databases, State, #{}),
    case maps:get(DatabaseId, Databases, undefined) of
        Existing = #{generation := Generation} ->
            Stale = maps:get(stale_replicas, Existing, []),
            Remaining = [Entry || Entry <- Stale,
                                  maps:get(server_id, Entry) =/= ServerId],
            Updated = case Remaining of
                          [] -> maps:remove(stale_replicas, Existing);
                          _ -> Existing#{stale_replicas => Remaining}
                      end,
            put_database(Updated, State);
        undefined -> {State, {error, database_not_found}};
        Existing -> {State, fence_error(Existing, Generation)}
    end.

replacement_available({_Name, ErlangNode} = Replacement, Databases, Nodes) ->
    ActiveNodes = [element(2, maps:get(server_id, NodeRecord))
                   || NodeRecord <- maps:values(Nodes),
                      maps:get(state, NodeRecord, active) =:= active],
    Used = lists:append(
             [maps:get(replicas, Database) ++ movement_replacements(Database)
              || Database <- maps:values(Databases),
                 maps:get(state, Database) =/= tombstoned]),
    lists:member(ErlangNode, ActiveNodes) andalso
        not lists:member(Replacement, Used).

movement_replacements(#{movement := #{replacement := Replacement}}) ->
    [Replacement];
movement_replacements(_) -> [].

put_database(Database = #{database_id := DatabaseId},
             State) ->
    Databases = maps:get(databases, State, #{}),
    {State#{databases => Databases#{DatabaseId => Database}}, ok}.

fence_error(#{generation := Current}, Supplied) when Supplied =/= Current ->
    {error, {stale_generation, Supplied, Current}};
fence_error(#{operation_id := Current}, _Generation) ->
    {error, {operation_id_conflict, Current}}.

valid_database_operation(DatabaseId, OperationId, Generation, Replicas) ->
    valid_identity(DatabaseId, OperationId, Generation) andalso
        is_list(Replicas) andalso length(Replicas) =:= 3 andalso
        length(lists:usort(Replicas)) =:= 3 andalso
        lists:all(fun valid_server_id/1, Replicas).

valid_identity(DatabaseId, OperationId, Generation) ->
    is_binary(DatabaseId) andalso byte_size(DatabaseId) > 0 andalso
        is_binary(OperationId) andalso byte_size(OperationId) =:= 16 andalso
        is_integer(Generation) andalso Generation > 0.

valid_server_id({Name, ErlangNode}) -> is_atom(Name) andalso is_atom(ErlangNode);
valid_server_id(_) -> false.

placement_available(DatabaseId, Replicas, Databases, Nodes) ->
    ActiveNodes = [element(2, maps:get(server_id, NodeRecord))
                   || NodeRecord <- maps:values(Nodes),
                      maps:get(state, NodeRecord, active) =:= active],
    PlacementNodesValid = lists:all(
                            fun({_Name, ErlangNode}) ->
                                    lists:member(ErlangNode, ActiveNodes)
                            end, Replicas),
    UsedByOthers = lists:append(
                     [maps:get(replicas, Database) ++
                          movement_replacements(Database)
                      || Database <- maps:values(Databases),
                         maps:get(database_id, Database) =/= DatabaseId,
                         maps:get(state, Database) =/= tombstoned]),
    PlacementNodesValid andalso
        not lists:any(fun(ServerId) -> lists:member(ServerId, UsedByOthers) end,
                      Replicas).

-spec status(state()) -> map().
status(State = #{nodes := Nodes}) ->
    Databases = maps:get(databases, State, #{}),
    (maps:without([nodes, databases], State))#{
      nodes => lists:sort(maps:values(Nodes)),
      databases => lists:sort(maps:values(Databases))}.

-spec database(binary(), state()) -> {ok, map()} | {error, database_not_found}.
database(DatabaseId, #{databases := Databases}) ->
    database_from_map(DatabaseId, Databases);
database(DatabaseId, _State) ->
    database_from_map(DatabaseId, #{}).

database_from_map(DatabaseId, Databases) ->
    case maps:find(DatabaseId, Databases) of
        {ok, Database} -> {ok, Database};
        error -> {error, database_not_found}
    end.

-spec recoverable(state()) -> [map()].
recoverable(State) ->
    Databases = maps:get(databases, State, #{}),
    lists:sort([Database || Database <- maps:values(Databases),
                            lists:member(maps:get(state, Database),
                                         [creating, deleting, restoring]) orelse
                            maps:is_key(movement, Database)]).
