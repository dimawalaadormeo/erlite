-module(erlite_raft_cluster).

-export([start/2, submit/3, committed_entries_after/3,
         stop_member/2, restart_member/2]).

-spec start(term(), [atom()]) -> {ok, [term()], [term()]} | {error, term()}.
start(ClusterName, MemberNames) when length(MemberNames) >= 3 ->
    ServerIds = [{Name, node()} || Name <- MemberNames],
    Machine = {module, erlite_raft_machine, #{}},
    ra:start_or_restart_cluster(default, ClusterName, Machine, ServerIds).

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

-spec committed_entries_after(term(), non_neg_integer(), timeout()) ->
    {ok, [term()]} | {error, term()} | {timeout, term()}.
committed_entries_after(ServerId, Index, Timeout) ->
    Query = fun(State) -> erlite_raft_machine:entries_after(State, Index) end,
    case ra:local_query(ServerId, Query, Timeout) of
        {ok, {{_RaftIndex, _Term}, Entries}, _Leader} -> {ok, Entries};
        Other -> Other
    end.

stop_member(System, ServerId) ->
    ra:stop_server(System, ServerId).

restart_member(System, ServerId) ->
    ra:restart_server(System, ServerId).
