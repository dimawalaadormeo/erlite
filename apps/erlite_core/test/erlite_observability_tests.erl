-module(erlite_observability_tests).

-include_lib("eunit/include/eunit.hrl").

counters_are_bounded_and_resettable_test() ->
    {ok, Pid} = erlite_observability:start_link(),
    unlink(Pid),
    try
        ok = erlite_observability:record(database_writes_total),
        ok = erlite_observability:record(database_writes_total, 2),
        #{counters := #{database_writes_total := 3}, vm := Vm} =
            erlite_observability:snapshot(),
        true = maps:get(process_count, Vm) > 0,
        ?assertEqual({error, invalid_metric},
                     erlite_observability:record(<<"unbounded-label">>)),
        ok = erlite_observability:reset(),
        #{counters := #{}} = erlite_observability:snapshot()
    after
        gen_server:stop(Pid)
    end.

health_is_degraded_without_catalog_test() ->
    application:unset_env(erlite_core, catalog_server),
    {ok, Pid} = erlite_observability:start_link(),
    unlink(Pid),
    try
        #{status := degraded, catalog := not_configured} =
            erlite_observability:health()
    after
        gen_server:stop(Pid)
    end.
