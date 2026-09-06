-module(erlite_raft_cluster).

-export([start/3, submit/3, checkpoint/4, barrier/2, committed_entries_after/3,
         committed_entries_after/5,
         stop_member/2, restart_member/2]).

-spec start(term(), [atom() | {atom(), node()}], map()) ->
    {ok, [term()], [term()]} | {error, term()}.
start(ClusterName, Members, RuntimeIdentity) when length(Members) >= 3 ->
    case erlite_sqlite_compatibility:validate(RuntimeIdentity) of
        ok ->
            ServerIds = [server_id(Member) || Member <- Members],
            Machine = {module, erlite_raft_machine,
                       #{runtime_identity => RuntimeIdentity}},
            ra:start_or_restart_cluster(
              default, ClusterName, Machine, ServerIds);
        {error, _Reason} = Error -> Error
    end.

server_id({Name, Node} = ServerId) when is_atom(Name), is_atom(Node) -> ServerId;
server_id(Name) when is_atom(Name) -> {Name, node()}.

-spec submit(term(), erlite_raft_command:command(), timeout()) ->
    {ok, non_neg_integer(), term()} | {error, term()} | {timeout, term()}.
submit(ServerId, Command, Timeout) ->
    case erlite_raft_command:validate(Command) of
        ok ->
            case ra:process_command(ServerId, Command, Timeout) of
                {ok, {committed, Index}, Leader} -> {ok, Index, Leader};
                {ok, {error, _Reason} = Error, _Leader} -> Error;
                Other -> Other
            end;
        {error, _Reason} = Error -> Error
    end.

-spec checkpoint(term(), non_neg_integer(), map(), timeout()) ->
    {ok, non_neg_integer(), term()} | {error, term()} | {timeout, term()}.
checkpoint(ServerId, ThroughIndex, Manifests, Timeout) ->
    case ra:process_command(
           ServerId, {checkpoint, ThroughIndex, Manifests}, Timeout) of
        {ok, {checkpointed, ThroughIndex}, Leader} ->
            {ok, ThroughIndex, Leader};
        {ok, {error, _Reason} = Error, _Leader} -> Error;
        Other -> Other
    end.

-spec barrier(term(), timeout()) ->
    {ok, map(), term()} | {error, term()} | {timeout, term()}.
barrier(ServerId, Timeout) ->
    ra:consistent_query(
      ServerId,
      {erlite_raft_machine, barrier, [], [with_context]}, Timeout).

-spec committed_entries_after(term(), non_neg_integer(), timeout()) ->
    {ok, [term()]} | {error, term()} | {timeout, term()}.
committed_entries_after(ServerId, Index, Timeout) ->
    Query = fun(State) ->
                    erlite_raft_machine:recovery_after(Index, ServerId, State)
            end,
    case ra:local_query(ServerId, Query, Timeout) of
        {ok, {{_RaftIndex, _Term}, {ok, Entries}}, _Leader} -> {ok, Entries};
        {ok, {{_RaftIndex, _Term}, {snapshot_required, Manifest}}, _Leader} ->
            {error, {snapshot_required, Manifest}};
        {ok, {{_RaftIndex, _Term}, {error, _} = Error}, _Leader} -> Error;
        Other -> Other
    end.
-spec committed_entries_after(term(), non_neg_integer(), non_neg_integer(),
                              non_neg_integer(), timeout()) ->
    {ok, [term()]} | {error, term()} | {timeout, term()}.
committed_entries_after(ServerId, Index, RequiredRaftIndex, RequiredTerm,
                        Timeout) ->
    Query = fun(State) ->
                    erlite_raft_machine:recovery_after(Index, ServerId, State)
            end,
    Options = #{condition => {applied, {RequiredRaftIndex, RequiredTerm}},
                timeout => Timeout},
    case ra:local_query(ServerId, Query, Options) of
        {ok, {{_RaftIndex, _Term}, {ok, Entries}}, _Leader} -> {ok, Entries};
        {ok, {{_RaftIndex, _Term}, {snapshot_required, Manifest}}, _Leader} ->
            {error, {snapshot_required, Manifest}};
        {ok, {{_RaftIndex, _Term}, {error, _} = Error}, _Leader} -> Error;
        Other -> Other
    end.

stop_member(System, ServerId) ->
    ra:stop_server(System, ServerId).

restart_member(System, ServerId) ->
    ra:restart_server(System, ServerId).
