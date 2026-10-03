-module(erlite_sqlite_owner).
-behaviour(gen_server).

-export([start_link/2, close/1, execute/3, query/3, readonly_query/3,
         readonly_query/4, dispatch_read/5, read_worker_pids/1, transaction/2,
         deadline/1, remaining/1, verify_runtime/3, validate_schema/2,
         last_applied_index/2,
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
                busy = #{} :: #{pid() => {reference(), reference()}},
                queue = {[], []} :: queue:queue(),
                pending = #{} :: #{reference() => {gen_server:from(),
                                                   reference() | none,
                                                   busy | queued}},
                queued = 0 :: non_neg_integer(),
                stale = 0 :: non_neg_integer(),
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
    readonly_query(Pid, Sql, Params, infinity).

-spec readonly_query(pid(), binary(), erlite_sqlite_adapter:params(),
                     timeout()) ->
    {ok, erlite_sqlite_adapter:query_result()} | {error, term()} |
    {timeout, read_query}.
readonly_query(Pid, Sql, Params, Timeout) ->
    bounded_call(Pid, {readonly_query, Sql, Params, deadline(Timeout)},
                 Timeout, {timeout, read_query}).

-spec dispatch_read(pid(), binary(), erlite_sqlite_adapter:params(),
                    gen_server:from(), infinity | integer()) ->
    ok | dispatch_timeout.
dispatch_read(Pid, Sql, Params, ReplyTo, Deadline) ->
    bounded_call(Pid, {dispatch_read, Sql, Params, ReplyTo, Deadline},
                 remaining(Deadline), dispatch_timeout).

%% Absolute monotonic deadlines (milliseconds) travel through the read path so
%% every sequential step uses the time that is actually left.
-spec deadline(timeout()) -> infinity | integer().
deadline(infinity) -> infinity;
deadline(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

-spec remaining(infinity | integer()) -> timeout().
remaining(infinity) -> infinity;
remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

bounded_call(Pid, Request, Timeout, Expired) ->
    try gen_server:call(Pid, Request, Timeout)
    catch
        exit:{timeout, _} -> Expired
    end.

-spec verify_runtime(pid(), term(), timeout()) -> term().
verify_runtime(Pid, Expected, Timeout) ->
    bounded_call(Pid, {verify_runtime, Expected}, Timeout,
                 {timeout, owner_call}).

-spec validate_schema(pid(), timeout()) -> term().
validate_schema(Pid, Timeout) ->
    bounded_call(Pid, validate_schema, Timeout, {timeout, owner_call}).

-spec last_applied_index(pid(), timeout()) -> term().
last_applied_index(Pid, Timeout) ->
    bounded_call(Pid, last_applied_index, Timeout, {timeout, owner_call}).

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
handle_call({readonly_query, Sql, Params, Deadline}, From, State) ->
    {noreply, enqueue_read(Sql, Params, From, Deadline, State)};
handle_call({dispatch_read, Sql, Params, ReplyTo, Deadline}, _From, State) ->
    {reply, ok, enqueue_read(Sql, Params, ReplyTo, Deadline, State)};
handle_call(read_worker_pids, _From, State = #state{readers = Readers}) ->
    {reply, Readers, State};
handle_call(read_pool_status, _From,
            State = #state{readers = Readers, busy = Busy, queued = Queued,
                           queue_limit = QueueLimit}) ->
    {reply, #{workers => length(Readers), busy => map_size(Busy),
              queued => Queued, queue_limit => QueueLimit}, State};
handle_call(close, _From, State = #state{busy = Busy})
  when map_size(Busy) =:= 0 ->
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
        {ok, {JobRef, ReqRef}} ->
            State1 = reply_request(ReqRef, Result,
                                   State#state{busy = maps:remove(Reader, Busy)}),
            maybe_finish_close(reader_available(Reader, State1));
        _ ->
            {noreply, State}
    end;
handle_info({timeout, _TimerRef, {read_deadline, ReqRef}},
            State = #state{pending = Pending}) ->
    case maps:take(ReqRef, Pending) of
        {{ReplyTo, _Timer, Kind}, Rest} ->
            gen_server:reply(ReplyTo, {timeout, read_query}),
            maybe_finish_close(forget_queued(
                                 Kind, State#state{pending = Rest}));
        error ->
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

enqueue_read(_Sql, _Params, ReplyTo, _Deadline,
             State = #state{closing = Closing}) when Closing =/= undefined ->
    gen_server:reply(ReplyTo, {error, owner_closing}),
    State;
enqueue_read(Sql, Params, ReplyTo, Deadline, State) ->
    case expired(Deadline) of
        true ->
            gen_server:reply(ReplyTo, {timeout, read_query}),
            State;
        false -> enqueue_live_read(Sql, Params, ReplyTo, Deadline, State)
    end.

expired(infinity) -> false;
expired(Deadline) -> erlang:monotonic_time(millisecond) >= Deadline.

enqueue_live_read(Sql, Params, ReplyTo, Deadline,
             State = #state{available = [Reader | Rest], busy = Busy}) ->
    ReqRef = make_ref(),
    JobRef = make_ref(),
    ok = erlite_sqlite_reader:query(Reader, Sql, Params, self(), JobRef),
    track_request(ReqRef, ReplyTo, Deadline, busy,
                  State#state{available = Rest,
                              busy = Busy#{Reader => {JobRef, ReqRef}}});
enqueue_live_read(Sql, Params, ReplyTo, Deadline,
             State = #state{queue = Queue, queued = Queued,
                            queue_limit = Limit}) ->
    case Queued < Limit of
        true ->
            ReqRef = make_ref(),
            track_request(ReqRef, ReplyTo, Deadline, queued,
                          State#state{queue = queue:in(
                                                {ReqRef, Sql, Params}, Queue),
                                      queued = Queued + 1});
        false ->
            gen_server:reply(ReplyTo, {error, read_pool_overloaded}),
            State
    end.

track_request(ReqRef, ReplyTo, infinity, Kind,
              State = #state{pending = Pending}) ->
    State#state{pending = Pending#{ReqRef => {ReplyTo, none, Kind}}};
track_request(ReqRef, ReplyTo, Deadline, Kind,
              State = #state{pending = Pending}) ->
    Timer = erlang:start_timer(remaining(Deadline), self(),
                               {read_deadline, ReqRef}),
    State#state{pending = Pending#{ReqRef => {ReplyTo, Timer, Kind}}}.

reply_request(ReqRef, Result, State = #state{pending = Pending}) ->
    case maps:take(ReqRef, Pending) of
        {{ReplyTo, Timer, _Kind}, Rest} ->
            cancel_deadline(Timer),
            gen_server:reply(ReplyTo, Result),
            State#state{pending = Rest};
        error ->
            State
    end.

cancel_deadline(none) -> ok;
cancel_deadline(Timer) -> _ = erlang:cancel_timer(Timer), ok.

%% Timed-out queued requests stay in the queue as stale entries and are skipped
%% when reached. Compacting once stale entries exceed the limit keeps the queue
%% bounded without an O(n) scan per timeout.
forget_queued(busy, State) ->
    State;
forget_queued(queued, State = #state{queued = Queued, stale = Stale,
                                     queue_limit = Limit}) ->
    State1 = State#state{queued = Queued - 1, stale = Stale + 1},
    case Stale + 1 > Limit of
        true -> compact_queue(State1);
        false -> State1
    end.

compact_queue(State = #state{queue = Queue, pending = Pending}) ->
    Live = queue:filter(fun({ReqRef, _Sql, _Params}) ->
                                maps:is_key(ReqRef, Pending)
                        end, Queue),
    State#state{queue = Live, stale = 0}.

reader_available(Reader, State) ->
    case next_live_read(State) of
        {ok, {ReqRef, Sql, Params}, State1 = #state{busy = Busy}} ->
            JobRef = make_ref(),
            ok = erlite_sqlite_reader:query(Reader, Sql, Params, self(), JobRef),
            State1#state{busy = Busy#{Reader => {JobRef, ReqRef}}};
        none ->
            State#state{available = State#state.available ++ [Reader]}
    end.

next_live_read(State = #state{queue = Queue, pending = Pending}) ->
    case queue:out(Queue) of
        {empty, _} ->
            none;
        {{value, {ReqRef, Sql, Params}}, Rest} ->
            case maps:find(ReqRef, Pending) of
                {ok, {ReplyTo, Timer, queued}} ->
                    {ok, {ReqRef, Sql, Params},
                     State#state{queue = Rest,
                                 pending = Pending#{ReqRef => {ReplyTo, Timer,
                                                               busy}},
                                 queued = State#state.queued - 1}};
                error ->
                    next_live_read(State#state{queue = Rest,
                                               stale = State#state.stale - 1})
            end
    end.

maybe_finish_close(State = #state{closing = undefined}) ->
    {noreply, State};
maybe_finish_close(State = #state{closing = CloseFrom, busy = Busy,
                                  queued = Queued}) ->
    case {map_size(Busy), Queued} of
        {0, 0} ->
            gen_server:reply(CloseFrom, ok),
            {stop, normal, State#state{closing = undefined}};
        _ -> {noreply, State}
    end.

reply_pending(Error, #state{pending = Pending}) ->
    maps:foreach(
      fun(_ReqRef, {ReplyTo, Timer, _Kind}) ->
              cancel_deadline(Timer),
              gen_server:reply(ReplyTo, Error)
      end, Pending).

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
