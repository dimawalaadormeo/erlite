-module(erlite_phase14_scale_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1,
         progressive_database_scale/1]).

all() -> [progressive_database_scale].

init_per_suite(Config) ->
    case os:getenv("ERLITE_SCALE_DATABASES") of
        false -> {skip, "set ERLITE_SCALE_DATABASES to 1000, 5000, or >=10000"};
        Text ->
            case parse_target(Text) of
                {ok, Target} -> start_cluster([{target, Target} | Config]);
                error -> {skip, "ERLITE_SCALE_DATABASES must be >= 1"}
            end
    end.

end_per_suite(Config) ->
    case proplists:get_value(supervisor, Config) of
        undefined -> ok;
        Sup ->
            DatabaseIds = case erlite_databases:list() of
                              {ok, Existing} -> Existing;
                              _ -> []
                          end,
            lists:foreach(fun(Id) -> _ = erlite_database_lifecycle:delete(Id) end,
                          DatabaseIds),
            lists:foreach(fun(ServerId) ->
                                  _ = ra:force_delete_server(default, ServerId)
                          end, proplists:get_value(catalog_servers, Config, [])),
            ok = gen_server:stop(Sup, normal, 5000),
            _ = application:stop(erlite_raft),
            _ = application:stop(ra),
            ok
    end.

progressive_database_scale(Config) ->
    Target = proplists:get_value(target, Config),
    Root = proplists:get_value(root, Config),
    Before = erlite_scale_metrics:snapshot(Root),
    {Ids, ProvisionUs, Checkpoints} = provision(Target, Root, Before),
    Samples = sampled_ids(Ids, 100),
    QueryUs = [timed(fun() ->
                             {ok, _} = erlite_databases:query(
                                         Id, <<"SELECT 1">>, [], 15000)
                     end) || Id <- Samples],
    ComponentMemory = component_memory(Samples),
    After = erlite_scale_metrics:snapshot(Root),
    Delta = erlite_scale_metrics:delta(Before, After),
    Report = #{format_version => 1,
               database_count => Target,
               replication_factor => 3,
               topology => single_vm_three_ra_members,
               checkpoints => Checkpoints,
               provisioning_latency =>
                   erlite_scale_metrics:summarize_latencies(ProvisionUs),
               query_latency =>
                   erlite_scale_metrics:summarize_latencies(QueryUs),
               sampled_component_memory => ComponentMemory,
               resource_delta => Delta,
               per_database => per_database(Delta, Target),
               omitted_distributed_measurements =>
                   [network_bytes, failover_latency, catch_up_time,
                    rebalance_throughput]},
    ReportPath = report_path(Root, Target),
    ok = file:write_file(ReportPath,
                         io_lib:format("~tp.~n", [Report]), [sync]),
    ct:pal("Phase 14 report (~s):~n~tp", [ReportPath, Report]),
    true = length(Ids) =:= Target,
    ok.

start_cluster(Config) ->
    Root = filename:join(
             "/tmp", "erlite-phase14-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    RaDir = filename:join(Root, "raft"),
    ok = filelib:ensure_dir(filename:join(RaDir, "placeholder")),
    {ok, _} = application:ensure_all_started(erlite_sqlite),
    {ok, _} = ra:start([{data_dir, RaDir}]),
    ok = application:start(erlite_raft),
    {ok, Sup} = erlite_core_sup:start_link(),
    unlink(Sup),
    CatalogNodes = catalog_nodes(),
    {ok, CatalogServers, []} = erlite_catalog:start(
                                 crypto:strong_rand_bytes(16),
                                 <<"phase14-scale">>, CatalogNodes),
    Catalog = hd(CatalogServers),
    ok = erlite_database_lifecycle:configure(Catalog, Root),
    [{root, Root}, {supervisor, Sup}, {catalog, Catalog},
     {catalog_servers, CatalogServers} | Config].

provision(Target, Root, Before) -> provision(1, Target, Root, Before, [], [], []).
provision(N, Target, _Root, _Before, Ids, Latencies, Checkpoints)
  when N > Target ->
    {lists:reverse(Ids), lists:reverse(Latencies), lists:reverse(Checkpoints)};
provision(N, Target, Root, Before, Ids, Latencies, Checkpoints) ->
    Id = iolist_to_binary(io_lib:format("scale-~8..0B", [N])),
    Us = timed(fun() -> ok = erlite_database_lifecycle:create(Id) end),
    NewCheckpoints = case milestone(N, Target) of
                         true ->
                             Snap = erlite_scale_metrics:snapshot(Root),
                             [#{database_count => N,
                                resource_delta =>
                                    erlite_scale_metrics:delta(Before, Snap)}
                              | Checkpoints];
                         false -> Checkpoints
                     end,
    provision(N + 1, Target, Root, Before, [Id | Ids], [Us | Latencies],
              NewCheckpoints).

milestone(N, Target) -> N =:= Target orelse N =:= 1000 orelse
                        N =:= 5000 orelse N =:= 10000.

sampled_ids(Ids, Limit) when length(Ids) =< Limit -> Ids;
sampled_ids(Ids, Limit) ->
    Step = max(1, length(Ids) div Limit),
    [Id || {Id, Index} <- lists:zip(Ids, lists:seq(1, length(Ids))),
           Index rem Step =:= 1].

timed(Fun) ->
    Started = erlang:monotonic_time(microsecond),
    _ = Fun(),
    erlang:monotonic_time(microsecond) - Started.

per_database(Delta, Count) ->
    maps:from_list([{Key, Value div Count}
                    || {Key, Value} <- maps:to_list(Delta),
                       is_integer(Value)]).

component_memory(Ids) ->
    Statuses = [Status || Id <- Ids,
                          {ok, Status} <- [erlite_databases:status(Id)]],
    Fields = [controller_memory_bytes, sqlite_owner_memory_bytes,
              raft_server_memory_bytes],
    maps:from_list(
      [component_field(Field, Statuses) || Field <- Fields,
                                           Statuses =/= []]).

component_field(Field, Statuses) ->
    Values = [maps:get(Field, Status) || Status <- Statuses],
    {Field, #{samples => length(Values),
              mean_bytes => lists:sum(Values) div length(Values)}}.

report_path(Root, Target) ->
    filename:join(Root, "phase14-" ++ integer_to_list(Target) ++ ".term").

parse_target(Text) ->
    try list_to_integer(Text) of
        N when N > 0 -> {ok, N};
        _ -> error
    catch error:badarg -> error
    end.

catalog_nodes() ->
    [#{node_id => <<N:128>>, node_name => integer_to_binary(N),
       server_id => ServerId}
     || {N, ServerId} <- lists:zip([141, 142, 143], catalog_server_ids())].

catalog_server_ids() ->
    [{Name, node()} || Name <- [erlite_scale_catalog_1,
                                erlite_scale_catalog_2,
                                erlite_scale_catalog_3]].
