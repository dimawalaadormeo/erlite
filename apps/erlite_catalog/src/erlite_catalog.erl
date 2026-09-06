-module(erlite_catalog).

-export([start/3, status/3, join/3, leave/3]).

-spec start(binary(), binary(), [map()]) ->
    {ok, [term()], [term()]} | {error, term()}.
start(ClusterId, ClusterName, Nodes) ->
    case validate(ClusterId, ClusterName, Nodes) of
        {ok, CanonicalNodes, ServerIds} ->
            Machine = {module, erlite_catalog_machine,
                       #{cluster_id => ClusterId,
                         cluster_name => ClusterName,
                         nodes => CanonicalNodes}},
            ra:start_or_restart_cluster(
              default, raft_cluster_name(ClusterId), Machine, ServerIds);
        {error, _Reason} = Error -> Error
    end.

-spec status(term(), timeout(), consistent | local) ->
    {ok, map()} | {error, term()} | {timeout, term()}.
status(ServerId, Timeout, consistent) ->
    normalize_query(ra:consistent_query(
                      ServerId, {erlite_catalog_machine, status, []}, Timeout));
status(ServerId, Timeout, local) ->
    normalize_query(ra:local_query(
                      ServerId, {erlite_catalog_machine, status, []}, Timeout)).

-spec join(term(), map(), timeout()) -> ok | {error, term()} | {timeout, term()}.
join(ServerRef, Node = #{server_id := NewServerId}, Timeout) ->
    case command(ServerRef, {prepare_join, Node}, Timeout) of
        ok -> join_prepared(ServerRef, NewServerId, Timeout);
        Other -> Other
    end;
join(_ServerRef, _Node, _Timeout) -> {error, invalid_node}.

join_prepared(ServerRef, NewServerId, Timeout) ->
    case {status(ServerRef, Timeout, consistent), ra:members(ServerRef, Timeout)} of
        {{ok, Status}, {ok, Members, _Leader}} ->
            Machine = machine(Status),
            ClusterName = raft_cluster_name(maps:get(cluster_id, Status)),
            case start_joining_server(ClusterName, NewServerId, Machine,
                                      Members, Timeout) of
                ok -> activate_joined(ServerRef, NewServerId, Timeout);
                Other -> Other
            end;
        {{error, _Reason} = Error, _} -> Error;
        {{timeout, _Where} = TimeoutError, _} -> TimeoutError;
        {_, Other} -> Other
    end.

start_joining_server(ClusterName, NewServerId, Machine, Members, Timeout) ->
    case ra:start_server(default, ClusterName, NewServerId, Machine,
                         lists:usort([NewServerId | Members])) of
        ok -> add_joining_member(Members, NewServerId, Timeout);
        {error, already_started} -> add_joining_member(Members, NewServerId, Timeout);
        {error, {already_started, _Pid}} ->
            add_joining_member(Members, NewServerId, Timeout);
        {error, _Reason} = Error -> Error
    end.

add_joining_member(Members, NewServerId, Timeout) ->
    case ra:add_member(Members, NewServerId, Timeout) of
        {ok, _Reply, Leader} -> wait_caught_up(NewServerId, Leader, Timeout);
        {error, already_member} -> wait_caught_up(NewServerId, Members, Timeout);
        Other -> Other
    end.

wait_caught_up(NewServerId, ServerRef, Timeout) ->
    Deadline = deadline(Timeout),
    wait_caught_up_loop(NewServerId, ServerRef, Deadline).

wait_caught_up_loop(NewServerId, ServerRef, Deadline) ->
    case status(NewServerId, remaining(Deadline), local) of
        {ok, _Status} ->
            case ra:members(ServerRef, remaining(Deadline)) of
                {ok, Members, _Leader} ->
                    case lists:member(NewServerId, Members) of
                        true -> ok;
                        false -> retry_catch_up(NewServerId, ServerRef, Deadline)
                    end;
                Other -> Other
            end;
        _ -> retry_catch_up(NewServerId, ServerRef, Deadline)
    end.

retry_catch_up(NewServerId, ServerRef, Deadline) ->
    case remaining(Deadline) of
        0 -> {error, join_catch_up_timeout};
        _ -> receive after 10 ->
                 wait_caught_up_loop(NewServerId, ServerRef, Deadline)
             end
    end.

activate_joined(ServerRef, NewServerId, Timeout) ->
    case wait_caught_up(NewServerId, ServerRef, Timeout) of
        ok ->
            case status(ServerRef, Timeout, consistent) of
                {ok, #{nodes := Nodes}} ->
                    NodeId = node_id_for_server(NewServerId, Nodes),
                    command(ServerRef, {activate_node, NodeId}, Timeout);
                Other -> Other
            end;
        Other -> Other
    end.

-spec leave(term(), binary(), timeout()) ->
    ok | {error, term()} | {timeout, term()} | timeout.
leave(ServerRef, NodeId, Timeout) when is_binary(NodeId) ->
    case status(ServerRef, Timeout, consistent) of
        {ok, #{nodes := Nodes}} ->
            case node_for_id(NodeId, Nodes) of
                {ok, #{server_id := LeavingServer}} ->
                    leave_known(ServerRef, NodeId, LeavingServer, Nodes, Timeout);
                error -> ok
            end;
        Other -> Other
    end.

leave_known(ServerRef, NodeId, LeavingServer, Nodes, Timeout) ->
    Active = [Node || Node = #{state := active} <- Nodes],
    case length(Active) > 3 of
        false -> {error, would_lose_catalog_quorum};
        true ->
            case command(ServerRef, {prepare_leave, NodeId}, Timeout) of
                ok -> remove_leaving_member(ServerRef, NodeId, LeavingServer,
                                            Nodes, Timeout);
                Other -> Other
            end
    end.

remove_leaving_member(ServerRef, NodeId, LeavingServer, Nodes, Timeout) ->
    Survivors = [maps:get(server_id, Node) || Node <- Nodes,
                 maps:get(server_id, Node) =/= LeavingServer],
    case ra:leave_and_delete_server(default, ServerRef, LeavingServer, Timeout) of
        ok -> command(Survivors, {finalize_leave, NodeId}, Timeout);
        {error, not_member} -> command(Survivors, {finalize_leave, NodeId}, Timeout);
        Other -> Other
    end.

command(ServerRef, Command, Timeout) ->
    case ra:process_command(ServerRef, Command, Timeout) of
        {ok, ok, _Leader} -> ok;
        {ok, {error, _Reason} = Error, _Leader} -> Error;
        Other -> Other
    end.

machine(#{cluster_id := ClusterId, cluster_name := ClusterName,
          nodes := Nodes}) ->
    {module, erlite_catalog_machine,
     #{cluster_id => ClusterId, cluster_name => ClusterName, nodes => Nodes}}.

node_id_for_server(ServerId, Nodes) ->
    maps:get(node_id, hd([Node || Node <- Nodes,
                                 maps:get(server_id, Node) =:= ServerId])).

node_for_id(NodeId, Nodes) ->
    case [Node || Node <- Nodes, maps:get(node_id, Node) =:= NodeId] of
        [Node] -> {ok, Node};
        [] -> error
    end.

deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

remaining(infinity) -> infinity;
remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

normalize_query({ok, {_IndexTerm, Status}, _Leader}) when is_map(Status) ->
    {ok, Status};
normalize_query({ok, Status, _Leader}) when is_map(Status) ->
    {ok, Status};
normalize_query(Other) -> Other.

validate(ClusterId, ClusterName, Nodes)
  when is_binary(ClusterId), byte_size(ClusterId) =:= 16,
       is_binary(ClusterName), byte_size(ClusterName) > 0,
       length(Nodes) >= 1, length(Nodes) =< 3 ->
    case lists:all(fun valid_node/1, Nodes) of
        true -> validate_unique(Nodes);
        false -> {error, invalid_catalog_nodes}
    end;
validate(ClusterId, _ClusterName, _Nodes)
  when not is_binary(ClusterId); byte_size(ClusterId) =/= 16 ->
    {error, invalid_cluster_id};
validate(_ClusterId, ClusterName, _Nodes)
  when not is_binary(ClusterName); byte_size(ClusterName) =:= 0 ->
    {error, invalid_cluster_name};
validate(_ClusterId, _ClusterName, _Nodes) ->
    {error, catalog_bootstrap_requires_one_to_three_nodes}.

valid_node(#{node_id := NodeId, node_name := NodeName,
             server_id := {ServerName, ErlangNode}})
  when is_binary(NodeId), byte_size(NodeId) =:= 16,
       is_binary(NodeName), byte_size(NodeName) > 0,
       is_atom(ServerName), is_atom(ErlangNode) -> true;
valid_node(_) -> false.

validate_unique(Nodes) ->
    NodeIds = [maps:get(node_id, Node) || Node <- Nodes],
    NodeNames = [maps:get(node_name, Node) || Node <- Nodes],
    ServerIds = [maps:get(server_id, Node) || Node <- Nodes],
    case {unique(NodeIds), unique(NodeNames), unique(ServerIds)} of
        {true, true, true} ->
            Canonical = lists:sort(
                          [Node#{state => active} || Node <- Nodes]),
            {ok, Canonical, ServerIds};
        {false, _, _} -> {error, duplicate_node_id};
        {_, false, _} -> {error, duplicate_node_name};
        {_, _, false} -> {error, duplicate_catalog_server_id}
    end.

unique(Values) -> length(lists:usort(Values)) =:= length(Values).

raft_cluster_name(ClusterId) ->
    <<"erlite-catalog-", (binary:encode_hex(ClusterId, lowercase))/binary>>.
