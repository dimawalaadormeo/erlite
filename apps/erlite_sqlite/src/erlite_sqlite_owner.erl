-module(erlite_sqlite_owner).
-behaviour(gen_server).

-export([start_link/2, close/1, execute/3, query/3, readonly_query/3, transaction/2,
         last_applied_index/1, schema_version/1, migration_history/1,
         migration_status/4,
         transaction_status/3, apply_committed/6, apply_committed/7,
         apply_migration/9,
         runtime_identity/1, verify_runtime/2, validate_schema/1,
         snapshot_into/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([readonly_query_connection/3]).
-endif.

-record(state, {connection :: erlite_sqlite:connection()}).

-spec start_link(file:filename_all(), binary()) -> gen_server:start_ret().
start_link(StorageRoot, DatabaseId) ->
    gen_server:start_link(?MODULE, {StorageRoot, DatabaseId}, []).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:stop(Pid).

-spec execute(pid(), binary(), erlite_sqlite_adapter:params()) ->
    {ok, erlite_sqlite_adapter:execute_result()} | {error, term()}.
execute(Pid, Sql, Params) ->
    gen_server:call(Pid, {execute, Sql, Params}, infinity).

-spec query(pid(), binary(), erlite_sqlite_adapter:params()) ->
    {ok, erlite_sqlite_adapter:query_result()} | {error, term()}.
query(Pid, Sql, Params) ->
    gen_server:call(Pid, {query, Sql, Params}, infinity).

-spec readonly_query(pid(), binary(), erlite_sqlite_adapter:params()) ->
    {ok, erlite_sqlite_adapter:query_result()} | {error, term()}.
readonly_query(Pid, Sql, Params) ->
    gen_server:call(Pid, {readonly_query, Sql, Params}, infinity).

-spec transaction(pid(), [erlite_sqlite_adapter:statement()]) ->
    {ok, [erlite_sqlite_adapter:statement_result()]} | {error, term()}.
transaction(Pid, Statements) ->
    gen_server:call(Pid, {transaction, Statements}, infinity).

-spec last_applied_index(pid()) -> {ok, non_neg_integer()} | {error, term()}.
last_applied_index(Pid) ->
    gen_server:call(Pid, last_applied_index, infinity).

schema_version(Pid) -> gen_server:call(Pid, schema_version, infinity).
migration_history(Pid) -> gen_server:call(Pid, migration_history, infinity).
migration_status(Pid, Set, MigrationId, CommandHash) ->
    gen_server:call(Pid, {migration_status, Set, MigrationId, CommandHash},
                    infinity).

-spec transaction_status(pid(), binary(), binary()) ->
    new | duplicate | rejected | conflict | {error, term()}.
transaction_status(Pid, TransactionId, CommandHash) ->
    gen_server:call(Pid, {transaction_status, TransactionId, CommandHash},
                    infinity).

-spec apply_committed(pid(), non_neg_integer(), pos_integer(), binary(), binary(),
                      non_neg_integer(),
                      [erlite_sqlite_adapter:statement()]) ->
    {ok, applied | already_applied | transaction_id_conflict} | {error, term()}.
apply_committed(Pid, ExpectedIndex, RaftIndex, TransactionId, CommandHash,
                Statements) ->
    gen_server:call(Pid, {apply_committed_legacy, ExpectedIndex, RaftIndex,
                          TransactionId, CommandHash, Statements}, infinity).

apply_committed(Pid, ExpectedIndex, RaftIndex, TransactionId, CommandHash,
                SchemaVersion,
                Statements) ->
    gen_server:call(
      Pid, {apply_committed, ExpectedIndex, RaftIndex, TransactionId,
            CommandHash, SchemaVersion, Statements}, infinity).

apply_migration(Pid, ExpectedIndex, RaftIndex, Set, MigrationId, CommandHash,
                FromVersion, ToVersion, Statements) ->
    gen_server:call(Pid, {apply_migration, ExpectedIndex, RaftIndex, Set,
                          MigrationId, CommandHash, FromVersion, ToVersion,
                          Statements}, infinity).

-spec runtime_identity(pid()) ->
    {ok, erlite_sqlite_compatibility:runtime_identity()} | {error, term()}.
runtime_identity(Pid) ->
    gen_server:call(Pid, runtime_identity, infinity).

-spec verify_runtime(pid(), erlite_sqlite_compatibility:runtime_identity()) ->
    ok | {error, term()}.
verify_runtime(Pid, Expected) ->
    gen_server:call(Pid, {verify_runtime, Expected}, infinity).

-spec validate_schema(pid()) -> ok | {error, term()}.
validate_schema(Pid) ->
    gen_server:call(Pid, validate_schema, infinity).

-spec snapshot_into(pid(), file:filename_all()) -> ok | {error, term()}.
snapshot_into(Pid, Destination) ->
    gen_server:call(Pid, {snapshot_into, Destination}, infinity).

init({StorageRoot, DatabaseId}) ->
    case erlite_sqlite_database:open(StorageRoot, DatabaseId) of
        {ok, Connection} -> {ok, #state{connection = Connection}};
        {error, Reason} -> {stop, {shutdown, Reason}}
    end.

handle_call({execute, Sql, Params}, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite:execute(Connection, Sql, Params), State};
handle_call({query, Sql, Params}, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite:query(Connection, Sql, Params), State};
handle_call({readonly_query, Sql, Params}, _From,
            State = #state{connection = Connection}) ->
    case readonly_query_connection(Connection, Sql, Params) of
        {ok, Result} -> {reply, Result, State};
        {fatal, Reason} -> {stop, Reason, State}
    end;
handle_call({transaction, Statements}, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite:transaction(Connection, Statements), State};
handle_call(last_applied_index, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite_schema:last_applied_index(Connection), State};
handle_call(schema_version, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite_schema:schema_version(Connection), State};
handle_call(migration_history, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite_schema:migration_history(Connection), State};
handle_call({migration_status, Set, MigrationId, CommandHash}, _From,
            State = #state{connection = Connection}) ->
    {reply, erlite_sqlite_schema:migration_status(
              Connection, Set, MigrationId, CommandHash), State};
handle_call({transaction_status, TransactionId, CommandHash}, _From,
            State = #state{connection = Connection}) ->
    {reply, erlite_sqlite_schema:transaction_status(
              Connection, TransactionId, CommandHash), State};
handle_call({apply_committed, ExpectedIndex, RaftIndex, TransactionId,
             CommandHash, SchemaVersion, Statements}, _From,
            State = #state{connection = Connection}) ->
    Reply = erlite_sqlite_schema:apply_committed(
              Connection, ExpectedIndex, RaftIndex, TransactionId,
              CommandHash, SchemaVersion, Statements),
    {reply, Reply, State};
handle_call({apply_committed_legacy, ExpectedIndex, RaftIndex, TransactionId,
             CommandHash, Statements}, _From,
            State = #state{connection = Connection}) ->
    Reply = erlite_sqlite_schema:apply_committed(
              Connection, ExpectedIndex, RaftIndex, TransactionId,
              CommandHash, Statements),
    {reply, Reply, State};
handle_call({apply_migration, ExpectedIndex, RaftIndex, Set, MigrationId,
             CommandHash, FromVersion, ToVersion, Statements}, _From,
            State = #state{connection = Connection}) ->
    Reply = erlite_sqlite_schema:apply_migration(
              Connection, ExpectedIndex, RaftIndex, Set, MigrationId,
              CommandHash, FromVersion, ToVersion, Statements),
    {reply, Reply, State};
handle_call(runtime_identity, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite_compatibility:runtime_identity(Connection), State};
handle_call({verify_runtime, Expected}, _From,
            State = #state{connection = Connection}) ->
    Reply = erlite_sqlite_compatibility:verify(Connection, Expected),
    {reply, Reply, State};
handle_call(validate_schema, _From, State = #state{connection = Connection}) ->
    Reply = erlite_sqlite_schema_policy:validate(Connection),
    {reply, Reply, State};
handle_call({snapshot_into, Destination}, _From,
            State = #state{connection = Connection}) ->
    Reply = case erlite_sqlite:execute(
                   Connection, <<"VACUUM INTO ?">>,
                   [unicode:characters_to_binary(Destination)]) of
                {ok, _} -> ok;
                {error, _Reason} = Error -> Error
            end,
    {reply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{connection = Connection}) ->
    _ = erlite_sqlite:close(Connection),
    ok.

readonly_query_connection(Connection, Sql, Params) ->
    case erlite_sqlite:execute(Connection, <<"PRAGMA query_only = ON">>, []) of
        {ok, _} ->
            Result = erlite_sqlite:query(Connection, Sql, Params),
            case erlite_sqlite:execute(
                   Connection, <<"PRAGMA query_only = OFF">>, []) of
                {ok, _} -> {ok, Result};
                {error, Reason} ->
                    {fatal, {query_only_reset_failed, Reason}}
            end;
        {error, Reason} ->
            {ok, {error, {query_only_enable_failed, Reason}}}
    end.
