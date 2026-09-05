-module(erlite_sqlite_schema).

-export([initialize/1, last_applied_index/1, apply_committed/3, apply_committed/4]).

-define(FORMAT_VERSION, 1).

-type apply_result() :: applied | already_applied.

-spec initialize(erlite_sqlite:connection()) -> ok | {error, term()}.
initialize(Connection) ->
    Statements = [
        {execute,
         <<"CREATE TABLE IF NOT EXISTS __erlite_replica_metadata ("
           "singleton INTEGER PRIMARY KEY CHECK (singleton = 1), "
           "format_version INTEGER NOT NULL, "
           "last_applied_raft_index INTEGER NOT NULL CHECK (last_applied_raft_index >= 0)"
           ")">>,
         []},
        {execute,
         <<"INSERT OR IGNORE INTO __erlite_replica_metadata "
           "(singleton, format_version, last_applied_raft_index) VALUES (1, ?, 0)">>,
         [?FORMAT_VERSION]}
    ],
    case erlite_sqlite:transaction(Connection, Statements) of
        {ok, _Results} -> verify_format(Connection);
        {error, _Reason} = Error -> Error
    end.

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

-spec apply_committed(erlite_sqlite:connection(), pos_integer(),
                      [erlite_sqlite_adapter:statement()]) ->
    {ok, apply_result()} | {error, term()}.
apply_committed(Connection, RaftIndex, Statements)
  when is_integer(RaftIndex), RaftIndex > 0, is_list(Statements) ->
    case validate_write_statements(Statements) of
        ok -> apply_after_index_check(Connection, RaftIndex, Statements);
        {error, _Reason} = Error -> Error
    end;
apply_committed(_Connection, RaftIndex, _Statements) ->
    {error, {invalid_raft_index, RaftIndex}}.

-spec apply_committed(erlite_sqlite:connection(), non_neg_integer(),
                      pos_integer(), [erlite_sqlite_adapter:statement()]) ->
    {ok, apply_result()} | {error, term()}.
apply_committed(Connection, ExpectedIndex, RaftIndex, Statements)
  when is_integer(ExpectedIndex), ExpectedIndex >= 0,
       is_integer(RaftIndex), RaftIndex > ExpectedIndex, is_list(Statements) ->
    case validate_write_statements(Statements) of
        ok -> apply_after_expected_index(Connection, ExpectedIndex,
                                         RaftIndex, Statements);
        {error, _Reason} = Error -> Error
    end;
apply_committed(_Connection, ExpectedIndex, RaftIndex, _Statements) ->
    {error, {invalid_raft_index_transition, ExpectedIndex, RaftIndex}}.

apply_after_expected_index(Connection, ExpectedIndex, RaftIndex, Statements) ->
    case last_applied_index(Connection) of
        {ok, CurrentIndex} when RaftIndex =< CurrentIndex ->
            {ok, already_applied};
        {ok, ExpectedIndex} ->
            apply_next(Connection, RaftIndex, Statements);
        {ok, CurrentIndex} ->
            {error, {raft_index_mismatch, ExpectedIndex, CurrentIndex, RaftIndex}};
        {error, _Reason} = Error -> Error
    end.

apply_after_index_check(Connection, RaftIndex, Statements) ->
    case last_applied_index(Connection) of
        {ok, CurrentIndex} when RaftIndex =< CurrentIndex ->
            {ok, already_applied};
        {ok, CurrentIndex} when RaftIndex =:= CurrentIndex + 1 ->
            apply_next(Connection, RaftIndex, Statements);
        {ok, CurrentIndex} ->
            {error, {raft_index_gap, CurrentIndex, RaftIndex}};
        {error, _Reason} = Error ->
            Error
    end.

apply_next(Connection, RaftIndex, Statements) ->
    UpdateIndex =
        {execute,
         <<"UPDATE __erlite_replica_metadata "
           "SET last_applied_raft_index = ? WHERE singleton = 1">>,
         [RaftIndex]},
    case erlite_sqlite:transaction(Connection, Statements ++ [UpdateIndex]) of
        {ok, _Results} -> {ok, applied};
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
