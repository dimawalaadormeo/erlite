-module(erlite_catalog_machine).
-behaviour(ra_machine).

-export([init/1, apply/3, status/1]).

-type node_record() :: #{node_id := binary(),
                         node_name := binary(),
                         server_id := {atom(), node()},
                         state := joining | active | leaving}.
-type state() :: #{cluster_id := binary(),
                   cluster_name := binary(),
                   replication_factor := 3,
                   quorum := 2,
                   nodes := #{binary() := node_record()}}.

-spec init(map()) -> state().
init(#{cluster_id := ClusterId, cluster_name := ClusterName,
       nodes := Nodes}) ->
    #{cluster_id => ClusterId,
      cluster_name => ClusterName,
      replication_factor => 3,
      quorum => 2,
      nodes => maps:from_list([{maps:get(node_id, Node), Node} || Node <- Nodes])}.

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

-spec status(state()) -> map().
status(State = #{nodes := Nodes}) ->
    (maps:without([nodes], State))#{nodes => lists:sort(maps:values(Nodes))}.
