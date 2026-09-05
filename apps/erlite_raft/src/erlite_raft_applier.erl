-module(erlite_raft_applier).

-export([catch_up/3, submit_and_apply/4]).

-spec catch_up(term(), pid(), timeout()) ->
    {ok, non_neg_integer()} | {error, term()} | {timeout, term()}.
catch_up(ServerId, Owner, Timeout) ->
    case erlite_sqlite_owner:validate_schema(Owner) of
        ok -> catch_up_valid_schema(ServerId, Owner, Timeout);
        {error, _Reason} = Error -> Error
    end.

catch_up_valid_schema(ServerId, Owner, Timeout) ->
    case erlite_sqlite_owner:last_applied_index(Owner) of
        {ok, AppliedIndex} ->
            case erlite_raft_cluster:committed_entries_after(
                   ServerId, AppliedIndex, Timeout) of
                {ok, Entries} -> apply_entries(Owner, AppliedIndex, Entries);
                Other -> Other
            end;
        {error, _Reason} = Error -> Error
    end.

-spec submit_and_apply(term(), erlite_raft_command:command(), pid(), timeout()) ->
    {ok, non_neg_integer(), term()} | {error, term()} | {timeout, term()}.
submit_and_apply(ServerId, Command, Owner, Timeout) ->
    case erlite_raft_cluster:submit(ServerId, Command, Timeout) of
        {ok, CommittedIndex, Leader} ->
            case catch_up(Leader, Owner, Timeout) of
                {ok, AppliedIndex} when AppliedIndex >= CommittedIndex ->
                    {ok, CommittedIndex, Leader};
                {ok, AppliedIndex} ->
                    {error, {sqlite_not_applied, CommittedIndex, AppliedIndex}};
                Other -> Other
            end;
        Other -> Other
    end.

apply_entries(_Owner, AppliedIndex, []) ->
    {ok, AppliedIndex};
apply_entries(Owner, AppliedIndex,
              [{RaftIndex, _Term, Command} | Rest]) ->
    Statements = erlite_raft_command:statements(Command),
    case erlite_sqlite_owner:apply_committed(
           Owner, AppliedIndex, RaftIndex, Statements) of
        {ok, applied} -> apply_entries(Owner, RaftIndex, Rest);
        {ok, already_applied} -> apply_entries(Owner, RaftIndex, Rest);
        {error, _Reason} = Error -> Error
    end.
