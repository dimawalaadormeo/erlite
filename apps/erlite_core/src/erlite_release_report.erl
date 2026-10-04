-module(erlite_release_report).

-export([run/0]).

-define(ATTEMPTS, 60).
-define(TIMEOUT, 5000).

%% Runs after the application starts, so a node that was upgraded in place
%% replaces the release recorded at its join. A node that is not in a cluster
%% has nothing to report.
run() ->
    case erlite_cluster_config:load() of
        {ok, #{storage_path := Root}} ->
            case erlite_cluster_metadata:load(Root) of
                {ok, #{state := active, catalog_server_id := ServerId}} ->
                    report(ServerId, ?ATTEMPTS);
                _ -> ok
            end;
        _ -> ok
    end.

report(_ServerId, 0) -> ok;
report(ServerId, Attempts) ->
    case erlite_catalog:update_release(ServerId, node(),
                                       erlite_release:metadata(), ?TIMEOUT) of
        ok -> ok;
        _ ->
            timer:sleep(1000),
            report(ServerId, Attempts - 1)
    end.
