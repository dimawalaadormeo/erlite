-module(erlite_api_limiter_tests).

-include_lib("eunit/include/eunit.hrl").

%% Each test starts its own limiter, so the budgets and read cap start clean.
limiter_test_() ->
    {foreach,
     fun start_limiter/0,
     fun stop_limiter/1,
     [fun per_source_budget_is_refused_and_recovers/0,
      fun budgets_are_independent_per_source/0,
      fun read_concurrency_is_capped/0,
      fun reads_fail_closed_without_limiter/0]}.

start_limiter() ->
    stop_running(whereis(erlite_api_limiter)),
    application:set_env(erlite_core, api_read_concurrency, 2),
    {ok, Pid} = erlite_api_limiter:start_link(),
    Pid.

stop_running(undefined) -> ok;
stop_running(Pid) -> gen_server:stop(Pid).

stop_limiter(Pid) ->
    case is_process_alive(Pid) of
        true ->
            unlink(Pid),
            gen_server:stop(Pid);
        false -> ok
    end,
    application:unset_env(erlite_core, api_read_concurrency).

per_source_budget_is_refused_and_recovers() ->
    Source = {192, 0, 2, 1},
    ?assertEqual(ok, erlite_api_limiter:admit(Source)),
    [ok = erlite_api_limiter:failed(Source) || _ <- lists:seq(1, 10)],
    ?assertEqual({error, rate_limited}, erlite_api_limiter:admit(Source)),
    %% The budget is 10 per second, so about 2 tokens return within 200 ms.
    timer:sleep(200),
    ?assertEqual(ok, erlite_api_limiter:admit(Source)).

budgets_are_independent_per_source() ->
    Noisy = {192, 0, 2, 2},
    Quiet = {192, 0, 2, 3},
    [ok = erlite_api_limiter:failed(Noisy) || _ <- lists:seq(1, 10)],
    ?assertEqual({error, rate_limited}, erlite_api_limiter:admit(Noisy)),
    ?assertEqual(ok, erlite_api_limiter:admit(Quiet)).

read_concurrency_is_capped() ->
    ?assertEqual(ok, erlite_api_limiter:acquire_read()),
    ?assertEqual(ok, erlite_api_limiter:acquire_read()),
    ?assertEqual({error, busy}, erlite_api_limiter:acquire_read()),
    ok = erlite_api_limiter:release_read(),
    ?assertEqual(ok, erlite_api_limiter:acquire_read()),
    ok = erlite_api_limiter:release_read(),
    ok = erlite_api_limiter:release_read().

%% Without a running limiter, reads and admission are refused, never allowed.
reads_fail_closed_without_limiter() ->
    Pid = whereis(erlite_api_limiter),
    unlink(Pid),
    gen_server:stop(Pid),
    ?assertEqual({error, busy}, erlite_api_limiter:acquire_read()),
    ?assertEqual({error, busy}, erlite_api_limiter:admit({192, 0, 2, 4})).
