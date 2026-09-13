-module(erlite_sqlite_owner).
-behaviour(gen_server).

-export([start_link/2, close/1, execute/3, query/3, readonly_query/3,
         dispatch_read/4, read_worker_pids/1, transaction/2,
         read_pool_status/1,
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

-define(MAX_READ_WORKERS, 8).
-define(MAX_READ_QUEUE, 65536).

-record(state, {connection :: erlite_sqlite:connection(),
                readers = [] :: [pid()],
                available = [] :: [pid()],
                busy = #{} :: #{pid() => {reference(), gen_server:from()}},
                queue = {[], []} :: queue:queue(),
                queue_limit = 64 :: non_neg_integer(),
                closing = undefined :: undefined | gen_server:from()}).

-spec start_link(file:filename_all(), binary()) -> gen_server:start_ret().
start_link(StorageRoot, DatabaseId) ->
    gen_server:start_link(?MODULE, {StorageRoot, DatabaseId}, []).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:call(Pid, close, infinity).

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

-spec dispatch_read(pid(), binary(), erlite_sqlite_adapter:params(),
                    gen_server:from()) -> ok.
dispatch_read(Pid, Sql, Params, ReplyTo) ->
    gen_server:call(Pid, {dispatch_read, Sql, Params, ReplyTo}, infinity).

-spec read_worker_pids(pid()) -> [pid()].
read_worker_pids(Pid) ->
    gen_server:call(Pid, read_worker_pids, infinity).

-spec read_pool_status(pid()) -> map().
read_pool_status(Pid) ->
    gen_server:call(Pid, read_pool_status, infinity).

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
    process_flag(trap_exit, true),
    case erlite_sqlite_database:open_writer(StorageRoot, DatabaseId) of
        {ok, Connection} ->
            case read_pool_config() of
                {ok, WorkerCount, QueueLimit} ->
                    case start_readers(StorageRoot, DatabaseId, WorkerCount,
                                       []) of
                        {ok, Readers} ->
                            {ok, #state{connection = Connection,
                                        readers = Readers,
                                        available = Readers,
                                        queue_limit = QueueLimit}};
                        {error, Reason} ->
                            _ = erlite_sqlite:close(Connection),
                            {stop, {shutdown,
                                    {read_worker_start_failed, Reason}}}
                    end;
                {error, Reason} ->
                    _ = erlite_sqlite:close(Connection),
                    {stop, {shutdown, Reason}}
            end;
        {error, Reason} -> {stop, {shutdown, Reason}}
    end.

handle_call({execute, Sql, Params}, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite:execute(Connection, Sql, Params), State};
handle_call({query, Sql, Params}, _From, State = #state{connection = Connection}) ->
    {reply, erlite_sqlite:query(Connection, Sql, Params), State};
handle_call({readonly_query, Sql, Params}, From,
            State) ->
    {noreply, enqueue_read(Sql, Params, From, State)};
handle_call({dispatch_read, Sql, Params, ReplyTo}, _From,
            State) ->
    {reply, ok, enqueue_read(Sql, Params, ReplyTo, State)};
handle_call(read_worker_pids, _From, State = #state{readers = Readers}) ->
    {reply, Readers, State};
handle_call(read_pool_status, _From,
            State = #state{readers = Readers, busy = Busy, queue = Queue,
                           queue_limit = QueueLimit}) ->
    {reply, #{workers => length(Readers), busy => map_size(Busy),
              queued => queue:len(Queue), queue_limit => QueueLimit}, State};
handle_call(close, _From,
            State = #state{busy = Busy, queue = Queue})
  when map_size(Busy) =:= 0 ->
    {empty, _} = queue:out(Queue),
    {stop, normal, ok, State};
handle_call(close, From, State = #state{closing = undefined}) ->
    {noreply, State#state{closing = From}};
handle_call(close, _From, State) ->
    {reply, {error, owner_closing}, State};
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

handle_info({read_complete, Reader, JobRef, Result},
            State = #state{busy = Busy}) ->
    case maps:find(Reader, Busy) of
        {ok, {JobRef, ReplyTo}} ->
            gen_server:reply(ReplyTo, Result),
            maybe_finish_close(
              reader_available(Reader,
                               State#state{busy = maps:remove(Reader, Busy)}));
        _ ->
            {noreply, State}
    end;
handle_info({'EXIT', Reader, Reason}, State = #state{readers = Readers}) ->
    case lists:member(Reader, Readers) of
        true ->
            reply_pending({error, {read_worker_failed, Reason}}, State),
            {stop, {read_worker_failed, Reason}, State};
        false ->
            reply_pending({error, {owner_stopped, Reason}}, State),
            {stop, Reason, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{connection = Connection, readers = Readers}) ->
    lists:foreach(fun close_reader/1, Readers),
    _ = erlite_sqlite:close(Connection),
    ok.

read_pool_config() ->
    WorkerCount = application:get_env(erlite_sqlite, read_worker_count, 1),
    QueueLimit = application:get_env(erlite_sqlite, read_queue_limit, 64),
    case {WorkerCount, QueueLimit} of
        {Workers, Limit}
          when is_integer(Workers), Workers >= 1,
               Workers =< ?MAX_READ_WORKERS,
               is_integer(Limit), Limit >= 0, Limit =< ?MAX_READ_QUEUE ->
            {ok, Workers, Limit};
        _ ->
            {error, {invalid_read_pool_config, WorkerCount, QueueLimit}}
    end.

start_readers(_StorageRoot, _DatabaseId, 0, Readers) ->
    {ok, lists:reverse(Readers)};
start_readers(StorageRoot, DatabaseId, Count, Readers) ->
    case erlite_sqlite_reader:start_link(StorageRoot, DatabaseId) of
        {ok, Reader} ->
            start_readers(StorageRoot, DatabaseId, Count - 1,
                          [Reader | Readers]);
        {error, Reason} ->
            lists:foreach(fun close_reader/1, Readers),
            {error, Reason}
    end.

enqueue_read(_Sql, _Params, ReplyTo,
             State = #state{closing = Closing}) when Closing =/= undefined ->
    gen_server:reply(ReplyTo, {error, owner_closing}),
    State;
enqueue_read(Sql, Params, ReplyTo,
             State = #state{available = [Reader | Rest], busy = Busy}) ->
    JobRef = make_ref(),
    ok = erlite_sqlite_reader:query(Reader, Sql, Params, self(), JobRef),
    State#state{available = Rest,
                busy = Busy#{Reader => {JobRef, ReplyTo}}};
enqueue_read(Sql, Params, ReplyTo,
             State = #state{queue = Queue, queue_limit = Limit}) ->
    case queue:len(Queue) < Limit of
        true -> State#state{queue = queue:in({Sql, Params, ReplyTo}, Queue)};
        false ->
            gen_server:reply(ReplyTo, {error, read_pool_overloaded}),
            State
    end.

reader_available(Reader, State = #state{queue = Queue, busy = Busy}) ->
    case queue:out(Queue) of
        {{value, {Sql, Params, ReplyTo}}, Rest} ->
            JobRef = make_ref(),
            ok = erlite_sqlite_reader:query(
                   Reader, Sql, Params, self(), JobRef),
            State#state{queue = Rest,
                        busy = Busy#{Reader => {JobRef, ReplyTo}}};
        {empty, _} ->
            State#state{available = State#state.available ++ [Reader]}
    end.

maybe_finish_close(State = #state{closing = undefined}) ->
    {noreply, State};
maybe_finish_close(State = #state{closing = CloseFrom, busy = Busy,
                                  queue = Queue}) ->
    case {map_size(Busy), queue:is_empty(Queue)} of
        {0, true} ->
            gen_server:reply(CloseFrom, ok),
            {stop, normal, State#state{closing = undefined}};
        _ -> {noreply, State}
    end.

reply_pending(Error, #state{busy = Busy, queue = Queue}) ->
    lists:foreach(
      fun({_Reader, {_JobRef, ReplyTo}}) -> gen_server:reply(ReplyTo, Error) end,
      maps:to_list(Busy)),
    lists:foreach(
      fun({_Sql, _Params, ReplyTo}) -> gen_server:reply(ReplyTo, Error) end,
      queue:to_list(Queue)).

close_reader(Reader) ->
    try erlite_sqlite_reader:close(Reader)
    catch
        exit:noproc -> ok;
        exit:{noproc, _Call} -> ok
    end.

-ifdef(TEST).
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
-endif.
