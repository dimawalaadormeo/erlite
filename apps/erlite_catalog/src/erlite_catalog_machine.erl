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
                     [maps:get(replicas, Database)
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
                                         [creating, deleting])]).
