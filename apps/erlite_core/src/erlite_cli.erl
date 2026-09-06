-module(erlite_cli).

-export([main/1, run/2]).

main(Arguments) ->
    Result = case erlite_cluster_config:load() of
                 {ok, Config} ->
                     start_runtime(Config, Arguments);
                 Error -> Error
             end,
    io:format("~tp~n", [Result]),
    case Result of
        {ok, _} -> halt(0);
        ok -> halt(0);
        _ -> halt(1)
    end.

start_runtime(#{storage_path := Root} = Config, Arguments) ->
    RaDir = filename:join(Root, "raft"),
    case ra:start([{data_dir, RaDir}]) of
        {ok, _} -> run(Arguments, Config);
        {error, {already_started, _}} -> run(Arguments, Config);
        Error -> Error
    end.

run(["init-cluster"], Config) -> erlite_cluster:init_cluster(Config);
run(["join", SeedServer], Config) ->
    case parse_server(SeedServer) of
        {ok, ServerId} -> erlite_cluster:join(ServerId, Config, 10000);
        Error -> Error
    end;
run(["leave"], #{storage_path := Root}) -> erlite_cluster:leave(Root, 10000);
run(["cluster", "status"], #{storage_path := Root}) ->
    erlite_cluster:status(Root, 10000);
run(_Arguments, _Config) -> {error, usage}.

parse_server(Name) when is_list(Name) ->
    case re:run(Name, "^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$",
                [{capture, none}]) of
        match -> {ok, {erlite_catalog, list_to_atom(Name)}};
        nomatch -> {error, invalid_seed_node}
    end.
