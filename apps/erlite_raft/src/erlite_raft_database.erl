-module(erlite_raft_database).

-export([write/4, consistent_read/5, catch_up/4, readiness/4,
         checkpoint/7]).

-type replicas() :: #{term() => pid()}.

-spec write(term(), erlite_raft_command:command(), replicas(), timeout()) ->
    {ok, non_neg_integer()} | {error, term()} | {timeout, term()}.
write(ServerRef, Command, Replicas, Timeout) ->
    case erlite_raft_cluster:submit(ServerRef, Command, Timeout) of
        {ok, CommittedIndex, Leader} ->
            case owner(Leader, Replicas) of
                {ok, Owner} ->
                    case erlite_raft_applier:catch_up(Leader, Owner, Timeout) of
                        {ok, AppliedIndex} when AppliedIndex >= CommittedIndex ->
                            write_status(Owner, Command, CommittedIndex);
                        {ok, AppliedIndex} ->
                            {error, {leader_sqlite_not_applied,
                                     CommittedIndex, AppliedIndex}};
                        Other -> Other
                    end;
                Error -> Error
            end;
        Other -> Other
    end.

write_status(Owner, Command, CommittedIndex) ->
    case erlite_raft_command:type(Command) of
        migration -> migration_status(Owner, Command, CommittedIndex);
        transaction -> transaction_status(Owner, Command, CommittedIndex)
    end.

transaction_status(Owner, Command, CommittedIndex) ->
    TransactionId = erlite_raft_command:transaction_id(Command),
    CommandHash = erlite_raft_command:hash(Command),
    case erlite_sqlite_owner:transaction_status(
           Owner, TransactionId, CommandHash) of
        duplicate -> {ok, CommittedIndex};
        conflict -> {error, {transaction_id_conflict, TransactionId}};
        new -> {error, {transaction_not_applied, TransactionId}};
        {error, _Reason} = Error -> Error
    end.

migration_status(Owner, Command, CommittedIndex) ->
    Target = erlite_raft_command:target_schema_version(Command),
    case erlite_sqlite_owner:schema_version(Owner) of
        {ok, Version} when Version >= Target ->
            {ok, CommittedIndex};
        {ok, Version} -> {error, {migration_not_applied, Version}};
        Error -> Error
    end.

-spec consistent_read(term(), binary(), list(), replicas(), timeout()) ->
    {ok, map()} | {error, term()} | {timeout, term()}.
consistent_read(ServerRef, Sql, Params, Replicas, Timeout) ->
    case erlite_raft_cluster:barrier(ServerRef, Timeout) of
        {ok, Barrier, Leader} ->
            case owner(Leader, Replicas) of
                {ok, Owner} ->
                    case erlite_raft_applier:catch_up(
                           Leader, Owner, Barrier, Timeout) of
                        {ok, _Index} ->
                            erlite_sqlite_owner:readonly_query(Owner, Sql, Params);
                        Other -> Other
                    end;
                Error -> Error
            end;
        Other -> Other
    end.

-spec catch_up(term(), replicas(), term(), timeout()) ->
    {ok, non_neg_integer()} | {error, term()} | {timeout, term()}.
catch_up(ServerRef, Replicas, ReplicaServerId, Timeout) ->
    case erlite_raft_cluster:barrier(ServerRef, Timeout) of
        {ok, Barrier, _Leader} ->
            case owner(ReplicaServerId, Replicas) of
                {ok, Owner} -> erlite_raft_applier:catch_up(
                                 ReplicaServerId, Owner, Barrier, Timeout);
                Error -> Error
            end;
        Other -> Other
    end.

-spec readiness(term(), replicas(), term(), timeout()) ->
    {ok, ready, non_neg_integer()} | {error, term()} | {timeout, term()}.
readiness(ServerRef, Replicas, ReplicaServerId, Timeout) ->
    case catch_up(ServerRef, Replicas, ReplicaServerId, Timeout) of
        {ok, Index} -> {ok, ready, Index};
        Other -> Other
    end.

-spec checkpoint(term(), replicas(), map(), binary(), non_neg_integer(),
                 non_neg_integer(), timeout()) ->
    {ok, non_neg_integer(), map()} | {error, term()} | {timeout, term()}.
checkpoint(ServerRef, Replicas, SnapshotRoots, DatabaseId, Generation,
           SchemaVersion, Timeout) ->
    case erlite_raft_cluster:barrier(ServerRef, Timeout) of
        {ok, Barrier, _Leader} ->
            case create_verified_snapshots(
                   maps:to_list(Replicas), SnapshotRoots, DatabaseId,
                   Generation, SchemaVersion, Barrier, Timeout, #{}) of
                {ok, Manifests} ->
                    ThroughIndex = maps:get(command_index, Barrier),
                    case erlite_raft_cluster:checkpoint(
                           ServerRef, ThroughIndex, Manifests, Timeout) of
                        {ok, ThroughIndex, _CheckpointLeader} ->
                            {ok, ThroughIndex, Manifests};
                        Other -> Other
                    end;
                Error -> Error
            end;
        Other -> Other
    end.

create_verified_snapshots([], _Roots, _DatabaseId, _Generation,
                          _SchemaVersion, _Barrier, _Timeout, Manifests) ->
    {ok, Manifests};
create_verified_snapshots([{ServerId, Owner} | Rest], Roots, DatabaseId,
                          Generation, SchemaVersion, Barrier, Timeout,
                          Manifests) ->
    case maps:find(ServerId, Roots) of
        error -> {error, {snapshot_root_unavailable, ServerId}};
        {ok, SnapshotRoot} ->
            case erlite_raft_applier:catch_up(
                   ServerId, Owner, Barrier, Timeout) of
                {ok, _} ->
                    Index = maps:get(command_index, Barrier),
                    Term = maps:get(command_term, Barrier),
                    case member_call(
                           ServerId, erlite_raft_snapshot, create,
                           [Owner, SnapshotRoot, DatabaseId, Generation,
                            Index, Term, SchemaVersion]) of
                        {ok, ManifestPath} ->
                            case member_call(
                                   ServerId, erlite_raft_snapshot, verify,
                                   [ManifestPath, DatabaseId, Generation,
                                    Index]) of
                                {ok, Manifest, _Image} ->
                                    Expected = maps:get(runtime_identity, Barrier),
                                    case maps:get(runtime_identity, Manifest) of
                                        Expected ->
                                            create_verified_snapshots(
                                              Rest, Roots, DatabaseId,
                                              Generation, SchemaVersion,
                                              Barrier, Timeout,
                                              Manifests#{ServerId => ManifestPath});
                                        _ -> {error, {snapshot_runtime_mismatch,
                                                      ServerId}}
                                    end;
                                {error, _Reason} = Error -> Error
                            end;
                        {error, _Reason} = Error -> Error
                    end;
                Other -> Other
            end
    end.

member_call({_, Node}, Module, Function, Arguments) when Node =:= node() ->
    erlang:apply(Module, Function, Arguments);
member_call({_, Node}, Module, Function, Arguments) ->
    case rpc:call(Node, Module, Function, Arguments) of
        {badrpc, Reason} -> {error, {replica_rpc_failed, Node, Reason}};
        Result -> Result
    end.

owner(ServerId, Replicas) ->
    case maps:find(ServerId, Replicas) of
        {ok, Owner} when is_pid(Owner) -> {ok, Owner};
        error -> {error, {replica_owner_unavailable, ServerId}}
    end.
