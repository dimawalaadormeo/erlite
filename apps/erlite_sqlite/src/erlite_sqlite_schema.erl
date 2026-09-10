-module(erlite_sqlite_schema).

-export([initialize/1, last_applied_index/1, schema_version/1,
         migration_history/1, transaction_status/3,
         apply_committed/6, apply_committed/7, apply_migration/9,
         reset_raft_history/1]).

-define(FORMAT_VERSION, 1).

-type apply_result() :: applied | already_applied | transaction_id_conflict |
                        transaction_failed | migration_failed.

-spec initialize(erlite_sqlite:connection()) -> ok | {error, term()}.
initialize(Connection) ->
    Statements = [
        {execute,
         <<"CREATE TABLE IF NOT EXISTS __erlite_replica_metadata ("
           "singleton INTEGER PRIMARY KEY CHECK (singleton = 1), "
           "format_version INTEGER NOT NULL, "
           "last_applied_raft_index INTEGER NOT NULL CHECK (last_applied_raft_index >= 0)"
           ", schema_version INTEGER NOT NULL DEFAULT 0 CHECK (schema_version >= 0)"
           ")">>,
         []},
        {execute,
         <<"INSERT OR IGNORE INTO __erlite_replica_metadata "
           "(singleton, format_version, last_applied_raft_index) VALUES (1, ?, 0)">>,
         [?FORMAT_VERSION]},
        {execute,
         <<"CREATE TABLE IF NOT EXISTS __erlite_migrations ("
           "migration_set BLOB NOT NULL, migration_id BLOB NOT NULL, "
           "from_version INTEGER NOT NULL, to_version INTEGER NOT NULL, "
           "command_hash BLOB NOT NULL, raft_index INTEGER NOT NULL, "
           "PRIMARY KEY (migration_set, migration_id))">>, []},
        {execute,
         <<"CREATE TABLE IF NOT EXISTS __erlite_transactions ("
           "transaction_id BLOB PRIMARY KEY, "
           "command_hash BLOB NOT NULL, "
           "original_raft_index INTEGER NOT NULL CHECK (original_raft_index > 0)"
         ")">>,
         []},
        {execute,
         <<"CREATE TABLE IF NOT EXISTS __erlite_transaction_failures ("
           "transaction_id BLOB PRIMARY KEY, command_hash BLOB NOT NULL, "
           "raft_index INTEGER NOT NULL, sqlite_error INTEGER NOT NULL)">>, []},
        {execute,
         <<"CREATE TABLE IF NOT EXISTS __erlite_migration_failures ("
           "migration_set BLOB NOT NULL, migration_id BLOB NOT NULL, "
           "command_hash BLOB NOT NULL, raft_index INTEGER NOT NULL, "
           "sqlite_error INTEGER NOT NULL, "
           "PRIMARY KEY (migration_set, migration_id))">>, []}
    ],
    case erlite_sqlite:transaction(Connection, Statements) of
        {ok, _Results} -> ensure_schema_version_column(Connection);
        {error, _Reason} = Error -> Error
    end.

ensure_schema_version_column(Connection) ->
    case erlite_sqlite:execute(Connection,
           <<"ALTER TABLE __erlite_replica_metadata ADD COLUMN "
             "schema_version INTEGER NOT NULL DEFAULT 0 CHECK (schema_version >= 0)">>, []) of
        {ok, _} -> verify_format(Connection);
        {error, _} -> verify_format(Connection)
    end.

schema_version(Connection) ->
    case erlite_sqlite:query(Connection,
           <<"SELECT schema_version FROM __erlite_replica_metadata WHERE singleton = 1">>, []) of
        {ok, #{rows := [[Version]]}} when is_integer(Version), Version >= 0 ->
            {ok, Version};
        {ok, #{rows := Rows}} -> {error, {invalid_schema_version, Rows}};
        Error -> Error
    end.

migration_history(Connection) ->
    erlite_sqlite:query(Connection,
      <<"SELECT migration_set, migration_id, from_version, to_version, raft_index "
        "FROM __erlite_migrations ORDER BY to_version">>, []).

-spec last_applied_index(erlite_sqlite:connection()) ->
    {ok, non_neg_integer()} | {error, term()}.
last_applied_index(Connection) ->
    Sql = <<"SELECT last_applied_raft_index "
            "FROM __erlite_replica_metadata WHERE singleton = 1">>,
    case erlite_sqlite:query(Connection, Sql, []) of
        {ok, #{rows := [[Index]]}} when is_integer(Index), Index >= 0 ->
            {ok, Index};
        {ok, #{rows := Rows}} ->
            {error, {invalid_replica_metadata, Rows}};
        {error, _Reason} = Error ->
            Error
    end.

-spec transaction_status(erlite_sqlite:connection(), binary(), binary()) ->
    new | duplicate | rejected | conflict | {error, term()}.
transaction_status(Connection, TransactionId, CommandHash) ->
    Sql = <<"SELECT command_hash FROM __erlite_transactions "
            "WHERE transaction_id = ?">>,
    case erlite_sqlite:query(Connection, Sql, [TransactionId]) of
        {ok, #{rows := []}} -> failed_transaction_status(
                                 Connection, TransactionId, CommandHash);
        {ok, #{rows := [[CommandHash]]}} -> duplicate;
        {ok, #{rows := [[_DifferentHash]]}} -> conflict;
        {ok, #{rows := Rows}} ->
            {error, {invalid_transaction_record, TransactionId, Rows}};
        {error, _Reason} = Error -> Error
    end.

failed_transaction_status(Connection, TransactionId, CommandHash) ->
    case erlite_sqlite:query(
           Connection,
           <<"SELECT command_hash FROM __erlite_transaction_failures "
             "WHERE transaction_id = ?">>, [TransactionId]) of
        {ok, #{rows := []}} -> new;
        {ok, #{rows := [[CommandHash]]}} -> rejected;
        {ok, #{rows := [[_DifferentHash]]}} -> conflict;
        {ok, #{rows := Rows}} ->
            {error, {invalid_transaction_failure_record, TransactionId, Rows}};
        {error, _Reason} = Error -> Error
    end.

-spec apply_committed(erlite_sqlite:connection(), non_neg_integer(),
                      pos_integer(), binary(), binary(), non_neg_integer(),
                      [erlite_sqlite_adapter:statement()]) ->
    {ok, apply_result()} | {error, term()}.
apply_committed(Connection, ExpectedIndex, RaftIndex, TransactionId,
                CommandHash, Statements) ->
    case schema_version(Connection) of
        {ok, Version} -> apply_committed(Connection, ExpectedIndex, RaftIndex,
                                         TransactionId, CommandHash, Version,
                                         Statements);
        Error -> Error
    end.

apply_committed(Connection, ExpectedIndex, RaftIndex, TransactionId, CommandHash,
                SchemaVersion,
                Statements)
  when is_integer(ExpectedIndex), ExpectedIndex >= 0,
       is_integer(RaftIndex), RaftIndex > ExpectedIndex,
       is_binary(TransactionId), byte_size(TransactionId) > 0,
       is_binary(CommandHash), byte_size(CommandHash) =:= 32,
       is_list(Statements) ->
    case validate_write_statements(Statements) of
        ok -> apply_after_expected_index(Connection, ExpectedIndex,
                                         RaftIndex, TransactionId,
                                         CommandHash, SchemaVersion, Statements);
        {error, _Reason} = Error -> Error
    end;
apply_committed(_Connection, ExpectedIndex, RaftIndex, _TransactionId,
                _CommandHash, _SchemaVersion, _Statements) ->
    {error, {invalid_raft_index_transition, ExpectedIndex, RaftIndex}}.

apply_after_expected_index(Connection, ExpectedIndex, RaftIndex, TransactionId,
                           CommandHash, SchemaVersion, Statements) ->
    case last_applied_index(Connection) of
        {ok, CurrentIndex} when RaftIndex =< CurrentIndex ->
            {ok, already_applied};
        {ok, ExpectedIndex} ->
            case schema_version(Connection) of
                {ok, SchemaVersion} -> apply_transaction(
                                         Connection, RaftIndex, TransactionId,
                                         CommandHash, Statements);
                {ok, Current} -> {error, {schema_version_mismatch,
                                          SchemaVersion, Current}};
                Error -> Error
            end;
        {ok, CurrentIndex} ->
            {error, {raft_index_mismatch, ExpectedIndex, CurrentIndex, RaftIndex}};
        {error, _Reason} = Error -> Error
    end.

apply_migration(Connection, ExpectedIndex, RaftIndex, Set, MigrationId,
                CommandHash, FromVersion, ToVersion, Statements) ->
    case validate_migration_statements(Statements) of
        ok -> apply_valid_migration(Connection, ExpectedIndex, RaftIndex, Set,
                                    MigrationId, CommandHash, FromVersion,
                                    ToVersion, Statements);
        Error -> Error
    end.

apply_valid_migration(Connection, ExpectedIndex, RaftIndex, Set, MigrationId,
                      CommandHash, FromVersion, ToVersion, Statements) ->
    case {last_applied_index(Connection), schema_version(Connection)} of
        {{ok, CurrentIndex}, _} when RaftIndex =< CurrentIndex ->
            {ok, already_applied};
        {{ok, ExpectedIndex}, {ok, FromVersion}} when ToVersion =:= FromVersion + 1 ->
            Record = {execute,
                      <<"INSERT INTO __erlite_migrations "
                        "(migration_set,migration_id,from_version,to_version,command_hash,raft_index) "
                        "VALUES (?,?,?,?,?,?)">>,
                      [Set, MigrationId, FromVersion, ToVersion, CommandHash,
                       RaftIndex]},
            Version = {execute,
                       <<"UPDATE __erlite_replica_metadata SET schema_version = ? "
                         "WHERE singleton = 1 AND schema_version = ?">>,
                       [ToVersion, FromVersion]},
            case commit_with_index(Connection, RaftIndex,
                                   Statements ++ [Record, Version], applied) of
                {error, SqliteError} = Error ->
                    case deterministic_migration_error(SqliteError) of
                        true -> record_migration_failure(
                                  Connection, RaftIndex, Set, MigrationId,
                                  CommandHash, SqliteError);
                        false -> Error
                    end;
                Result -> Result
            end;
        {{ok, ExpectedIndex}, {ok, ToVersion}} ->
            case migration_record(Connection, Set, MigrationId) of
                {ok, CommandHash, FromVersion, ToVersion} ->
                    commit_with_index(Connection, RaftIndex, [], already_applied);
                {ok, _Hash, _OldFrom, _OldTo} ->
                    {error, {migration_id_conflict, Set, MigrationId}};
                not_found -> {error, {schema_version_mismatch,
                                      FromVersion, ToVersion}};
                Error -> Error
            end;
        {{ok, ExpectedIndex}, {ok, Current}} ->
            {error, {schema_version_mismatch, FromVersion, Current}};
        {{ok, Current}, _} ->
            {error, {raft_index_mismatch, ExpectedIndex, Current, RaftIndex}};
        {Error, _} -> Error
    end.

validate_migration_statements([]) -> {error, empty_migration};
validate_migration_statements([{execute, Sql, Params} | Rest])
  when is_binary(Sql), is_list(Params) ->
    case placeholder_count(Sql) =:= length(Params) of
        false -> {error, unsafe_migration_sql};
        true ->
            case erlite_sqlite_schema_policy:validate_migration_statement(Sql) of
                ok -> validate_remaining_migration_statements(Rest);
                Error -> Error
            end
    end;
validate_migration_statements([Statement | _]) ->
    {error, {invalid_migration_statement, Statement}}.

validate_remaining_migration_statements([]) -> ok;
validate_remaining_migration_statements(Statements) ->
    validate_migration_statements(Statements).

placeholder_count(Sql) ->
    length([C || <<C>> <= Sql, C =:= $?]).

migration_record(Connection, Set, MigrationId) ->
    case erlite_sqlite:query(Connection,
           <<"SELECT command_hash, from_version, to_version "
             "FROM __erlite_migrations WHERE migration_set = ? AND migration_id = ?">>,
           [Set, MigrationId]) of
        {ok, #{rows := [[Hash, From, To]]}} -> {ok, Hash, From, To};
        {ok, #{rows := []}} -> not_found;
        {ok, #{rows := Rows}} -> {error, {invalid_migration_history, Rows}};
        Error -> Error
    end.

%% SQLITE_ERROR (1) covers deterministic DDL errors such as an existing table.
%% Resource and I/O failures are deliberately not acknowledged: their Raft
%% index remains unapplied until storage recovers.
deterministic_migration_error(1) -> true;
deterministic_migration_error(_) -> false.

record_migration_failure(Connection, RaftIndex, Set, MigrationId, CommandHash,
                         SqliteError) ->
    Failure = {execute,
               <<"INSERT OR IGNORE INTO __erlite_migration_failures "
                 "(migration_set,migration_id,command_hash,raft_index,sqlite_error) "
                 "VALUES (?,?,?,?,?)">>,
               [Set, MigrationId, CommandHash, RaftIndex, SqliteError]},
    commit_with_index(Connection, RaftIndex, [Failure], migration_failed).

apply_transaction(Connection, RaftIndex, TransactionId, CommandHash, Statements) ->
    case transaction_status(Connection, TransactionId, CommandHash) of
        new ->
            record_and_apply(Connection, RaftIndex, TransactionId,
                             CommandHash, Statements);
        duplicate ->
            advance_duplicate(Connection, RaftIndex);
        conflict ->
            commit_with_index(Connection, RaftIndex, [],
                              transaction_id_conflict);
        rejected ->
            commit_with_index(Connection, RaftIndex, [], transaction_failed);
        {error, _Reason} = Error -> Error
    end.

record_and_apply(Connection, RaftIndex, TransactionId, CommandHash, Statements) ->
    Record =
        {execute,
         <<"INSERT INTO __erlite_transactions "
           "(transaction_id, command_hash, original_raft_index) VALUES (?, ?, ?)">>,
         [TransactionId, CommandHash, RaftIndex]},
    case commit_with_index(Connection, RaftIndex, Statements ++ [Record],
                           applied) of
        {error, SqliteError} = Error ->
            case deterministic_transaction_error(SqliteError) of
                true -> record_transaction_failure(
                          Connection, RaftIndex, TransactionId, CommandHash,
                          SqliteError);
                false -> Error
            end;
        Result -> Result
    end.

%% Only errors determined by command content or the replicated schema become
%% durable rejections. Busy/locked, full disk, I/O, corruption, interruption,
%% and allocation failures remain unapplied and retryable.
deterministic_transaction_error(SqliteError) when is_integer(SqliteError) ->
    lists:member(SqliteError band 16#ff, [1, 18, 19, 20]);
deterministic_transaction_error(_) -> false.

record_transaction_failure(Connection, RaftIndex, TransactionId, CommandHash,
                           SqliteError) ->
    Failure = {execute,
               <<"INSERT OR IGNORE INTO __erlite_transaction_failures "
                 "(transaction_id,command_hash,raft_index,sqlite_error) "
                 "VALUES (?,?,?,?)">>,
               [TransactionId, CommandHash, RaftIndex, SqliteError]},
    commit_with_index(Connection, RaftIndex, [Failure], transaction_failed).

advance_duplicate(Connection, RaftIndex) ->
    commit_with_index(Connection, RaftIndex, [], already_applied).

commit_with_index(Connection, RaftIndex, Statements, Result) ->
    UpdateIndex =
        {execute,
         <<"UPDATE __erlite_replica_metadata "
           "SET last_applied_raft_index = ? WHERE singleton = 1">>,
         [RaftIndex]},
    case erlite_sqlite:transaction(Connection, Statements ++ [UpdateIndex]) of
        {ok, _Results} -> {ok, Result};
        {error, _Reason} = Error -> Error
    end.

validate_write_statements([]) ->
    ok;
validate_write_statements([{execute, Sql, Params} | Rest])
  when is_binary(Sql), is_list(Params) ->
    validate_write_statements(Rest);
validate_write_statements([Statement | _Rest]) ->
    {error, {invalid_replicated_statement, Statement}}.

verify_format(Connection) ->
    Sql = <<"SELECT format_version FROM __erlite_replica_metadata WHERE singleton = 1">>,
    case erlite_sqlite:query(Connection, Sql, []) of
        {ok, #{rows := [[?FORMAT_VERSION]]}} -> ok;
        {ok, #{rows := [[Version]]}} -> {error, {unsupported_format_version, Version}};
        {ok, #{rows := Rows}} -> {error, {invalid_replica_metadata, Rows}};
        {error, _Reason} = Error -> Error
    end.

%% This is only valid while materializing an offline backup under a new
%% database generation.  It deliberately preserves user schema and data while
%% severing every reference to the source Raft history.
-spec reset_raft_history(erlite_sqlite:connection()) -> ok | {error, term()}.
reset_raft_history(Connection) ->
    Statements = [
        {execute, <<"DELETE FROM __erlite_transactions">>, []},
        {execute, <<"DELETE FROM __erlite_transaction_failures">>, []},
        {execute, <<"DELETE FROM __erlite_migration_failures">>, []},
        {execute,
         <<"UPDATE __erlite_replica_metadata "
           "SET last_applied_raft_index = 0 WHERE singleton = 1">>, []}
    ],
    case erlite_sqlite:transaction(Connection, Statements) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.
