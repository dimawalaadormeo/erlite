-module(erlite_api_limiter).

%% Admission control for bearer tokens that the local catalog replica does not
%% recognise. A miss may need a consistent catalog read, so misses are budgeted
%% per source address and globally, and the number of concurrent reads is capped.
%% Valid tokens found on the local replica never pass through here.

-behaviour(gen_server).

-export([start_link/0, admit/1, failed/1, acquire_read/0, release_read/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PER_SOURCE_PER_SECOND, 10).
-define(GLOBAL_PER_SECOND, 200).
-define(READ_CONCURRENCY, 32).
-define(PRUNE_INTERVAL_MS, 60000).
-define(READS_KEY, {?MODULE, reads}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Admits a miss only when both budgets have a token. Does not consume one.
-spec admit(term()) -> ok | {error, rate_limited}.
admit(Source) ->
    try gen_server:call(?MODULE, {admit, Source})
    catch exit:_ -> {error, busy}
    end.

%% Charges one failed lookup against both budgets. Called only after the
%% catalog has confirmed the token is not valid.
-spec failed(term()) -> ok.
failed(Source) ->
    gen_server:call(?MODULE, {failed, Source}).

%% Reserves a slot for a consistent token read. Fails closed when the limiter
%% is not running, so reads cannot bypass the cap.
-spec acquire_read() -> ok | {error, busy}.
acquire_read() ->
    case persistent_term:get(?READS_KEY, undefined) of
        {Ref, Limit} ->
            counters:add(Ref, 1, 1),
            case counters:get(Ref, 1) of
                N when N =< Limit -> ok;
                _ ->
                    counters:sub(Ref, 1, 1),
                    {error, busy}
            end;
        undefined -> {error, busy}
    end.

-spec release_read() -> ok.
release_read() ->
    case persistent_term:get(?READS_KEY, undefined) of
        {Ref, _Limit} -> counters:sub(Ref, 1, 1);
        undefined -> ok
    end,
    ok.

init([]) ->
    Limit = application:get_env(erlite_core, api_read_concurrency, ?READ_CONCURRENCY),
    Ref = counters:new(1, [atomics]),
    persistent_term:put(?READS_KEY, {Ref, Limit}),
    erlang:send_after(?PRUNE_INTERVAL_MS, self(), prune),
    {ok, #{sources => #{}, global => full_bucket(?GLOBAL_PER_SECOND, now_ms())}}.

handle_call({admit, Source}, _From, State) ->
    Now = now_ms(),
    {Source1, Global1} = refill(Source, Now, State),
    Reply = case has_token(Source1) andalso has_token(Global1) of
                true -> ok;
                false -> {error, rate_limited}
            end,
    {reply, Reply, store(Source, Source1, Global1, State)};
handle_call({failed, Source}, _From, State) ->
    Now = now_ms(),
    {Source1, Global1} = refill(Source, Now, State),
    {reply, ok, store(Source, take(Source1), take(Global1), State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(prune, State = #{sources := Sources}) ->
    Now = now_ms(),
    Kept = maps:filter(fun(_Source, Bucket) ->
                               not is_full(Bucket, ?PER_SOURCE_PER_SECOND, Now)
                       end, Sources),
    erlang:send_after(?PRUNE_INTERVAL_MS, self(), prune),
    {noreply, State#{sources => Kept}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    persistent_term:erase(?READS_KEY),
    ok.

%% Buckets hold a token count and the time it was last refilled. Each bucket
%% refills at its per-second rate and holds at most one second of budget.
refill(Source, Now, #{sources := Sources, global := Global}) ->
    SourceBucket = maps:get(Source, Sources, full_bucket(?PER_SOURCE_PER_SECOND, Now)),
    {refill_bucket(SourceBucket, ?PER_SOURCE_PER_SECOND, Now),
     refill_bucket(Global, ?GLOBAL_PER_SECOND, Now)}.

store(Source, SourceBucket, GlobalBucket, State = #{sources := Sources}) ->
    State#{sources => Sources#{Source => SourceBucket}, global => GlobalBucket}.

full_bucket(Rate, Now) -> {Rate * 1.0, Now}.

refill_bucket({Tokens, Last}, Rate, Now) ->
    Elapsed = max(0, Now - Last),
    {min(Rate * 1.0, Tokens + Elapsed * Rate / 1000), Now}.

has_token({Tokens, _Last}) -> Tokens >= 1.

take({Tokens, Last}) -> {Tokens - 1, Last}.

is_full({Tokens, Last}, Rate, Now) ->
    refill_bucket({Tokens, Last}, Rate, Now) =:= {Rate * 1.0, Now}.

now_ms() -> erlang:monotonic_time(millisecond).
