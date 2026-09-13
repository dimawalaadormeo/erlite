-module(erlite_read_bench).

-export([main/0]).

-define(TIMEOUT, 15000).

main() ->
    Nodes = ['erlite_a@node-a', 'erlite_b@node-b', 'erlite_c@node-c'],
    ok = await_nodes(Nodes, 60),
    Queue = env_integer("ERLITE_BENCH_QUEUE_LIMIT", 64),
    Duration = env_integer("ERLITE_BENCH_DURATION_SECONDS", 10),
    Concurrency = env_integer("ERLITE_BENCH_CONCURRENCY", 16),
    WritePercent = env_integer("ERLITE_BENCH_WRITE_PERCENT", 20),
    SeedRows = env_integer("ERLITE_BENCH_SEED_ROWS", 50000),
    Profiles = env_atoms("ERLITE_BENCH_PROFILES",
                         [point, range_aggregate, recursive, write_heavy]),
    Readers = env_integers("ERLITE_BENCH_READERS", [1, 2, 4, 8]),
    ok = bootstrap(Nodes),
    Results = [run_variant(Nodes, Count, Queue, Duration, Concurrency,
                           WritePercent, SeedRows, Profiles) || Count <- Readers],
    Report = #{format_version => 1,
               topology => three_containers_single_host,
               limitations => [shared_host_cpu, shared_host_storage,
                               bridge_network_not_production_network],
               otp_release => erlang:system_info(otp_release),
               duration_seconds => Duration,
               concurrency => Concurrency,
               write_percent => WritePercent,
               seed_rows => SeedRows,
               profiles => Profiles,
               queue_limit => Queue,
               variants => Results},
    Output = os:getenv("ERLITE_BENCH_OUTPUT", "/results/read-benchmark.term"),
    ok = file:write_file(Output, io_lib:format("~tp.~n", [Report]), [sync]),
    io:format("~tp~n", [Report]),
    halt(0).

bootstrap([NodeA, NodeB, NodeC]) ->
    ConfigA = config(NodeA),
    {ok, _} = rpc:call(NodeA, erlite_cluster, init_cluster, [ConfigA]),
    Seed = {erlite_catalog, NodeA},
    {ok, _} = rpc:call(NodeB, erlite_cluster, join,
                       [Seed, config(NodeB), ?TIMEOUT]),
    {ok, _} = rpc:call(NodeC, erlite_cluster, join,
                       [Seed, config(NodeC), ?TIMEOUT]),
    ok.

config(Node) ->
    #{storage_path => "/data", node_name => atom_to_binary(Node),
      cluster_name => <<"read-benchmark">>, replication_factor => 3,
      seed_nodes => []}.

run_variant(Nodes = [NodeA | _], Readers, Queue, Duration, Concurrency,
            WritePercent, SeedRows, Profiles) ->
    lists:foreach(
      fun(Node) -> ok = rpc:call(Node, erlite_read_bench_node, configure,
                                 [Readers, Queue]) end, Nodes),
    DatabaseId = iolist_to_binary(io_lib:format("read-bench-~B", [Readers])),
    ok = rpc:call(NodeA, erlite_database_lifecycle, create, [DatabaseId]),
    {ok, Migration} = erlite_raft_command:new_migration(
                        <<"benchmark">>, <<"create-rows">>, 0, 1,
                        [{<<"CREATE TABLE bench_rows "
                            "(id INTEGER PRIMARY KEY, value INTEGER NOT NULL)">>,
                          []}]),
    {ok, _} = rpc:call(NodeA, erlite_databases, migrate,
                       [DatabaseId, Migration, ?TIMEOUT]),
    ok = rpc:call(NodeA, erlite_read_bench_node, seed,
                  [DatabaseId, SeedRows], ?TIMEOUT),
    Before = node_metrics(Nodes, DatabaseId),
    ProfileResults = maps:from_list(
      [{Profile, workload(NodeA, DatabaseId, Duration, Concurrency,
                          profile_write_percent(Profile, WritePercent), Profile,
                          SeedRows)} || Profile <- Profiles]),
    After = node_metrics(Nodes, DatabaseId),
    Checkpoint = checkpoint_probe(NodeA, DatabaseId, Nodes),
    Lifecycle = lifecycle_probe(NodeA, DatabaseId),
    Failures = failure_probe(NodeA, DatabaseId),
    #{readers => Readers,
      profile_results => ProfileResults,
      checkpoint_probe => Checkpoint,
      lifecycle_probe => Lifecycle,
      failure_probe => Failures,
      before => Before, 'after' => After}.

workload(Node, DatabaseId, Duration, Concurrency, WritePercent, Profile,
         SeedRows) ->
    End = erlang:monotonic_time(millisecond) + Duration * 1000,
    Parent = self(),
    [spawn(fun() -> worker(Parent, Node, DatabaseId, End, WritePercent, Profile,
                           SeedRows, N, 0)
           end) || N <- lists:seq(1, Concurrency)],
    Samples = collect(Concurrency, [], [], #{}),
    #{reads => summarize(maps:get(reads, Samples)),
      writes => summarize(maps:get(writes, Samples)),
      errors => maps:get(errors, Samples)}.

worker(Parent, Node, DatabaseId, End, WritePercent, Profile, SeedRows, Worker,
       Sequence) ->
    case erlang:monotonic_time(millisecond) >= End of
        true -> Parent ! {done, self()};
        false ->
            IsWrite = (Sequence rem 100) < WritePercent,
            Started = erlang:monotonic_time(microsecond),
            Result = operation(IsWrite, Node, DatabaseId, Profile, SeedRows,
                               Worker, Sequence),
            Elapsed = erlang:monotonic_time(microsecond) - Started,
            Parent ! {sample, IsWrite, Elapsed, Result},
            worker(Parent, Node, DatabaseId, End, WritePercent, Profile,
                   SeedRows, Worker, Sequence + 1)
    end.

operation(false, Node, DatabaseId, point, SeedRows, _Worker, Sequence) ->
    rpc:call(Node, erlite_databases, query,
             [DatabaseId, <<"SELECT value FROM bench_rows WHERE id = ?">>,
              [(Sequence rem SeedRows) + 1], ?TIMEOUT]);
operation(false, Node, DatabaseId, range_aggregate, SeedRows, _Worker,
          Sequence) ->
    Start = (Sequence rem max(1, SeedRows - 1000)) + 1,
    rpc:call(Node, erlite_databases, query,
             [DatabaseId,
              <<"SELECT sum(value) FROM bench_rows WHERE id BETWEEN ? AND ?">>,
              [Start, Start + 999], ?TIMEOUT]);
operation(false, Node, DatabaseId, recursive, _SeedRows, _Worker, _Sequence) ->
    rpc:call(Node, erlite_databases, query,
             [DatabaseId,
              <<"WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL "
                "SELECT n + 1 FROM seq WHERE n < 10000) SELECT sum(n) FROM seq">>,
              [], ?TIMEOUT]);
operation(false, Node, DatabaseId, write_heavy, SeedRows, Worker, Sequence) ->
    operation(false, Node, DatabaseId, point, SeedRows, Worker, Sequence);
operation(true, Node, DatabaseId, Profile, _SeedRows, Worker, Sequence) ->
    TxId = iolist_to_binary(
             io_lib:format("bench-~s-~B-~B",
                           [atom_to_list(Profile), Worker, Sequence])),
    Offset = profile_offset(Profile),
    write(Node, DatabaseId, TxId,
          Offset + Worker * 1000000000 + Sequence, Sequence).

profile_write_percent(write_heavy, _Default) -> 80;
profile_write_percent(_, Default) -> Default.

profile_offset(point) -> 10000000000000;
profile_offset(range_aggregate) -> 20000000000000;
profile_offset(recursive) -> 30000000000000;
profile_offset(write_heavy) -> 40000000000000.

write(Node, DatabaseId, TxId, Id, Value) ->
    {ok, Command} = erlite_raft_command:new_transaction(
                      TxId, 1,
                      [{<<"INSERT INTO bench_rows(id, value) VALUES(?, ?)">>,
                        [Id, Value]}]),
    rpc:call(Node, erlite_databases, write,
             [DatabaseId, Command, ?TIMEOUT]).

lifecycle_probe(Node, DatabaseId) ->
    {CoolUs, Cool} = timed(fun() ->
                                  rpc:call(Node, erlite_databases, cool,
                                           [DatabaseId])
                          end),
    {ReactivateUs, Reactivate} = timed(fun() ->
            rpc:call(Node, erlite_databases, query,
                     [DatabaseId, <<"SELECT count(*) FROM bench_rows">>, [],
                      ?TIMEOUT])
                                      end),
    {BackupUs, Backup} = timed(fun() ->
            rpc:call(Node, erlite_database_lifecycle, backup, [DatabaseId])
                               end),
    #{cool => Cool, cool_us => CoolUs,
      reactivate => normalize_result(Reactivate), reactivate_us => ReactivateUs,
      snapshot => normalize_result(Backup), snapshot_us => BackupUs}.

failure_probe(Node, DatabaseId) ->
    case rpc:call(Node, erlite_databases, placement, [DatabaseId]) of
        {ok, #{server_ids := ServerIds}} ->
            case rpc:call(Node, ra, members, [ServerIds, 5000]) of
                {ok, Members, Leader} ->
                    [Follower | _] = lists:delete(Leader, Members),
                    FollowerNode = element(2, Follower),
                    StopFollower = rpc:call(FollowerNode, ra, stop_server,
                                            [default, Follower]),
                    {FollowerWriteUs, FollowerWrite} = timed(fun() ->
                        write(Node, DatabaseId, <<"failure-follower">>,
                              9000000000001, 1)
                                                             end),
                    RestartFollower = rpc:call(FollowerNode, ra, restart_server,
                                               [default, Follower]),
                    LeaderNode = element(2, Leader),
                    StopLeader = rpc:call(LeaderNode, ra, stop_server,
                                          [default, Leader]),
                    {FailoverUs, FailoverWrite} = timed(fun() ->
                        retry_write(Node, DatabaseId, <<"failure-leader">>,
                                    9000000000002, 2,
                                    erlang:monotonic_time(millisecond) + ?TIMEOUT)
                                                       end),
                    RestartLeader = rpc:call(LeaderNode, ra, restart_server,
                                             [default, Leader]),
                    #{leader => Leader, follower => Follower,
                      stop_follower => StopFollower,
                      follower_loss_write => normalize_result(FollowerWrite),
                      follower_loss_write_us => FollowerWriteUs,
                      restart_follower => RestartFollower,
                      stop_leader => StopLeader,
                      failover_write => normalize_result(FailoverWrite),
                      failover_us => FailoverUs,
                      restart_old_leader => RestartLeader};
                Other -> #{error => {members_failed, Other}}
            end;
        Other -> #{error => {placement_failed, Other}}
    end.

retry_write(Node, DatabaseId, TxId, Id, Value, Deadline) ->
    case write(Node, DatabaseId, TxId, Id, Value) of
        {ok, _} = Ok -> Ok;
        Last ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> Last;
                false -> timer:sleep(50),
                         retry_write(Node, DatabaseId, TxId, Id, Value, Deadline)
            end
    end.

timed(Fun) ->
    Started = erlang:monotonic_time(microsecond),
    Result = Fun(),
    {erlang:monotonic_time(microsecond) - Started, Result}.

normalize_result({ok, _}) -> ok;
normalize_result(Result) -> Result.

checkpoint_probe(Node, DatabaseId, Nodes) ->
    Before = node_metrics(Nodes, DatabaseId),
    {Elapsed, Result} = timed(fun() ->
        rpc:call(Node, erlite_read_bench_node, checkpoint, [DatabaseId], ?TIMEOUT)
                              end),
    #{result => Result, duration_us => Elapsed,
      before => Before, 'after' => node_metrics(Nodes, DatabaseId)}.

collect(0, Reads, Writes, Errors) ->
    #{reads => Reads, writes => Writes, errors => Errors};
collect(Workers, Reads, Writes, Errors) ->
    receive
        {done, _} -> collect(Workers - 1, Reads, Writes, Errors);
        {sample, IsWrite, Elapsed, {ok, _}} ->
            case IsWrite of
                true -> collect(Workers, Reads, [Elapsed | Writes], Errors);
                false -> collect(Workers, [Elapsed | Reads], Writes, Errors)
            end;
        {sample, _IsWrite, _Elapsed, Error} ->
            Key = error_key(Error),
            collect(Workers, Reads, Writes,
                    Errors#{Key => maps:get(Key, Errors, 0) + 1})
    end.

error_key({error, Reason}) -> Reason;
error_key({timeout, _}) -> timeout;
error_key({badrpc, _}) -> badrpc;
error_key(_) -> unexpected_error.

summarize(Values) -> erlite_scale_metrics:summarize_latencies(Values).

node_metrics(Nodes, DatabaseId) ->
    maps:from_list([{Node, rpc:call(Node, erlite_read_bench_node, metrics,
                                    [DatabaseId])} || Node <- Nodes]).

await_nodes(_Nodes, 0) -> error(nodes_unavailable);
await_nodes(Nodes, Attempts) ->
    case lists:all(fun(Node) -> net_adm:ping(Node) =:= pong end, Nodes) of
        true -> ok;
        false -> timer:sleep(1000), await_nodes(Nodes, Attempts - 1)
    end.

env_integer(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Text -> list_to_integer(Text)
    end.

env_integers(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Text -> [list_to_integer(string:trim(Value)) ||
                    Value <- string:split(Text, ",", all)]
    end.

env_atoms(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Text -> [list_to_existing_atom(string:trim(Value)) ||
                    Value <- string:split(Text, ",", all)]
    end.
