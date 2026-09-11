-module(erlite_scale_metrics).

-export([snapshot/1, delta/2, summarize_latencies/1]).

snapshot(Root) when is_list(Root) ->
    Memory = maps:from_list(erlang:memory()),
    {ContextSwitches, _} = erlang:statistics(context_switches),
    {Reductions, _} = erlang:statistics(reductions),
    #{monotonic_us => erlang:monotonic_time(microsecond),
      memory_bytes => maps:get(total, Memory),
      process_memory_bytes => maps:get(processes, Memory),
      process_count => erlang:system_info(process_count),
      port_count => erlang:system_info(port_count),
      file_descriptors => descriptor_count(),
      reductions => Reductions,
      context_switches => ContextSwitches,
      disk_bytes => directory_bytes(Root)}.

delta(Before, After) when is_map(Before), is_map(After) ->
    maps:from_list(
      [{Key, maps:get(Key, After) - maps:get(Key, Before)}
       || Key <- [monotonic_us, memory_bytes, process_memory_bytes,
                  process_count, port_count, reductions, context_switches,
                  disk_bytes],
          maps:is_key(Key, Before), maps:is_key(Key, After)] ++
      descriptor_delta(Before, After)).

summarize_latencies([]) ->
    #{samples => 0};
summarize_latencies(Values) when is_list(Values) ->
    Sorted = lists:sort(Values),
    Count = length(Sorted),
    #{samples => Count,
      min_us => hd(Sorted),
      p50_us => percentile(Sorted, 50),
      p95_us => percentile(Sorted, 95),
      p99_us => percentile(Sorted, 99),
      max_us => lists:last(Sorted),
      mean_us => lists:sum(Sorted) div Count}.

percentile(Sorted, Percent) ->
    Index = max(1, (length(Sorted) * Percent + 99) div 100),
    lists:nth(Index, Sorted).

descriptor_delta(#{file_descriptors := Before},
                 #{file_descriptors := After})
  when is_integer(Before), is_integer(After) ->
    [{file_descriptors, After - Before}];
descriptor_delta(_, _) -> [].

descriptor_count() ->
    case file:list_dir("/proc/self/fd") of
        {ok, Entries} -> length(Entries);
        {error, _} -> unavailable
    end.

directory_bytes(Root) -> directory_bytes([Root], 0).

directory_bytes([], Total) -> Total;
directory_bytes([Path | Rest], Total) ->
    case file:read_file_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    directory_bytes(
                      [filename:join(Path, Name) || Name <- Names] ++ Rest,
                      Total);
                {error, _} -> directory_bytes(Rest, Total)
            end;
        {ok, Info} -> directory_bytes(Rest, Total + element(2, Info));
        {error, _} -> directory_bytes(Rest, Total)
    end.
