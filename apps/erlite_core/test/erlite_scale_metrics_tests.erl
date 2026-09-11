-module(erlite_scale_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

latency_summary_uses_nearest_rank_test() ->
    Summary = erlite_scale_metrics:summarize_latencies(lists:seq(1, 100)),
    ?assertEqual(100, maps:get(samples, Summary)),
    ?assertEqual(50, maps:get(p50_us, Summary)),
    ?assertEqual(95, maps:get(p95_us, Summary)),
    ?assertEqual(99, maps:get(p99_us, Summary)),
    ?assertEqual(50, maps:get(mean_us, Summary)).

empty_latency_summary_test() ->
    ?assertEqual(#{samples => 0},
                 erlite_scale_metrics:summarize_latencies([])).

snapshot_and_delta_test() ->
    Root = filename:join("/tmp", "erlite-scale-metrics-missing"),
    Before = erlite_scale_metrics:snapshot(Root),
    After = erlite_scale_metrics:snapshot(Root),
    Delta = erlite_scale_metrics:delta(Before, After),
    ?assert(maps:is_key(memory_bytes, Delta)),
    ?assert(maps:is_key(disk_bytes, Delta)),
    ?assert(maps:is_key(reductions, Delta)).
