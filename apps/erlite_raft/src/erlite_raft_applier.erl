-module(erlite_raft_applier).

-export([catch_up/3, catch_up/4]).
-ifdef(TEST).
-export([submit_and_apply/4]).
-endif.

-spec catch_up(term(), pid(), timeout()) ->
    {ok, non_neg_integer()} | {error, term()} | {timeout, term()}.
catch_up(ServerId, Owner, Timeout) ->
    case erlite_raft_cluster:barrier(ServerId, Timeout) of
        {ok, Barrier, _Leader} -> catch_up(ServerId, Owner, Barrier, Timeout);
        Other -> Other
    end.

-spec catch_up(term(), pid(), map(), timeout()) ->
    {ok, non_neg_integer()} | {error, term()} | {timeout, term()}.
catch_up(ServerId, Owner,
         #{raft_index := RaftIndex, term := Term,
           command_index := RequiredCommandIndex,
           runtime_identity := RuntimeIdentity}, Timeout) ->
    case erlite_sqlite_owner:verify_runtime(Owner, RuntimeIdentity) of
        ok -> catch_up_compatible(ServerId, Owner, RaftIndex, Term,
                                  RequiredCommandIndex, Timeout);
        {error, _Reason} = Error -> Error
    end.

catch_up_compatible(ServerId, Owner, RaftIndex, Term, RequiredCommandIndex,
                    Timeout) ->
    case erlite_sqlite_owner:validate_schema(Owner) of
        ok -> catch_up_through(ServerId, Owner, RaftIndex, Term,
                               RequiredCommandIndex, Timeout);
        {error, _Reason} = Error -> Error
    end.

catch_up_through(ServerId, Owner, RaftIndex, Term, RequiredCommandIndex,
                 Timeout) ->
    case erlite_sqlite_owner:last_applied_index(Owner) of
        {ok, AppliedIndex} ->
            case erlite_raft_cluster:committed_entries_after(
                   ServerId, AppliedIndex, RaftIndex, Term, Timeout) of
                {ok, Entries} ->
                    case apply_entries(Owner, AppliedIndex, Entries) of
                        {ok, FinalIndex} when FinalIndex >= RequiredCommandIndex ->
                            {ok, FinalIndex};
                        {ok, FinalIndex} ->
                            {error, {replica_not_caught_up,
                                     RequiredCommandIndex, FinalIndex}};
                        Other -> Other
                    end;
                Other -> Other
            end;
        {error, _Reason} = Error -> Error
    end.

-ifdef(TEST).
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
-endif.

apply_entries(_Owner, AppliedIndex, []) ->
    {ok, AppliedIndex};
apply_entries(Owner, AppliedIndex,
              [{RaftIndex, _Term, Command} | Rest]) ->
    Result = case erlite_raft_command:type(Command) of
        transaction ->
            erlite_sqlite_owner:apply_committed(
              Owner, AppliedIndex, RaftIndex,
              erlite_raft_command:transaction_id(Command),
              erlite_raft_command:hash(Command),
              erlite_raft_command:schema_version(Command),
              erlite_raft_command:statements(Command));
        migration ->
            erlite_sqlite_owner:apply_migration(
              Owner, AppliedIndex, RaftIndex,
              erlite_raft_command:migration_set(Command),
              erlite_raft_command:migration_id(Command),
              erlite_raft_command:hash(Command),
              erlite_raft_command:schema_version(Command),
              erlite_raft_command:target_schema_version(Command),
              erlite_raft_command:statements(Command))
    end,
    case Result of
        {ok, applied} -> apply_entries(Owner, RaftIndex, Rest);
        {ok, already_applied} -> apply_entries(Owner, RaftIndex, Rest);
        {ok, transaction_id_conflict} -> apply_entries(Owner, RaftIndex, Rest);
        {ok, transaction_failed} -> apply_entries(Owner, RaftIndex, Rest);
        {ok, migration_failed} -> apply_entries(Owner, RaftIndex, Rest);
        {error, _Reason} = Error -> Error
    end.
