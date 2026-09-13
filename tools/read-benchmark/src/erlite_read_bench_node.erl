-module(erlite_read_bench_node).

-export([start/0, configure/2, metrics/1, seed/2, checkpoint/1]).

start() ->
    Root = os:getenv("ERLITE_BENCH_ROOT", "/data"),
    ok = filelib:ensure_dir(filename:join(Root, "raft/placeholder")),
    {ok, _} = application:ensure_all_started(erlite_sqlite),
    {ok, _} = ra:start([{data_dir, filename:join(Root, "raft")}]),
    ok = application:start(erlite_raft),
    {ok, _} = application:ensure_all_started(erlite_core),
    receive stop -> ok end.

configure(Readers, QueueLimit) ->
    ok = application:set_env(erlite_sqlite, read_worker_count, Readers),
    ok = application:set_env(erlite_sqlite, read_queue_limit, QueueLimit).

seed(DatabaseId, Rows) when is_integer(Rows), Rows > 0 ->
    with_database_state(
      DatabaseId,
      fun(#{replicas := Replicas, server_ids := ServerIds}) ->
              CatchUps = [erlite_raft_database:catch_up(
                            ServerIds, Replicas, ServerId, 15000) ||
                             ServerId <- ServerIds],
              true = lists:all(fun({ok, _}) -> true; (_) -> false end,
                               CatchUps),
              Sql = <<"WITH RECURSIVE seq(n) AS "
                      "(SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < ?) "
                      "INSERT INTO bench_rows(id, value) SELECT n, n FROM seq">>,
              Results = [erlite_sqlite_owner:execute(Owner, Sql, [Rows]) ||
                            Owner <- maps:values(Replicas)],
              case lists:all(fun({ok, _}) -> true; (_) -> false end, Results) of
                  true -> ok;
                  false -> {error, {seed_failed, Results}}
              end
      end).

checkpoint(DatabaseId) ->
    with_database_state(
      DatabaseId,
      fun(#{replicas := Replicas, server_ids := ServerIds}) ->
              case ra:members(ServerIds, 5000) of
                  {ok, _Members, Leader} ->
                      erlite_sqlite_owner:query(
                        maps:get(Leader, Replicas),
                        <<"PRAGMA wal_checkpoint(PASSIVE)">>, []);
                  Other -> Other
              end
      end).

with_database_state(DatabaseId, Fun) ->
    case ets:lookup(erlite_database_routes, DatabaseId) of
        [{DatabaseId, Controller}] -> Fun(sys:get_state(Controller));
        [] -> {error, database_not_found}
    end.

metrics(DatabaseId) ->
    Root = os:getenv("ERLITE_BENCH_ROOT", "/data"),
    Memory = maps:from_list(erlang:memory()),
    Status = case erlite_databases:status(DatabaseId) of
                 {ok, Value} -> Value;
                 _ -> #{}
             end,
    #{memory_bytes => maps:get(total, Memory),
      process_memory_bytes => maps:get(processes, Memory),
      process_count => erlang:system_info(process_count),
      file_descriptors => descriptor_count(),
      database_bytes => suffix_bytes(Root, ".sqlite"),
      wal_bytes => suffix_bytes(Root, ".sqlite-wal"),
      shm_bytes => suffix_bytes(Root, ".sqlite-shm"),
      database_status => Status}.

descriptor_count() ->
    case file:list_dir("/proc/self/fd") of
        {ok, Entries} -> length(Entries);
        _ -> unavailable
    end.

suffix_bytes(Root, Suffix) -> suffix_bytes([Root], Suffix, 0).
suffix_bytes([], _Suffix, Total) -> Total;
suffix_bytes([Path | Rest], Suffix, Total) ->
    case file:read_file_info(Path) of
        {ok, Info} when element(3, Info) =:= directory ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    suffix_bytes([filename:join(Path, N) || N <- Names] ++ Rest,
                                 Suffix, Total);
                _ -> suffix_bytes(Rest, Suffix, Total)
            end;
        {ok, Info} ->
            Added = case lists:suffix(Suffix, Path) of
                        true -> element(2, Info);
                        false -> 0
                    end,
            suffix_bytes(Rest, Suffix, Total + Added);
        _ -> suffix_bytes(Rest, Suffix, Total)
    end.
