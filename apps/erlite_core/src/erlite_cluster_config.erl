-module(erlite_cluster_config).

-export([load/0, resolve/2]).

-type config() :: #{storage_path := file:filename(),
                    node_name := binary(),
                    cluster_name := binary(),
                    replication_factor := 3,
                    seed_nodes := [binary()] }.
-export_type([config/0]).

-define(MAX_NAME_BYTES, 255).

-spec load() -> {ok, config()} | {error, term()}.
load() ->
    Keys = [storage_path, node_name, cluster_name,
            replication_factor, seed_nodes],
    Application = maps:from_list(
                    [{Key, Value} || Key <- Keys,
                                     {ok, Value} <- [application:get_env(
                                                        erlite_core, Key)]]),
    Environment = maps:from_list(
                    [{Key, Value} || {Key, Name} <- environment_names(),
                                     Value <- getenv(Name)]),
    resolve(Application, Environment).

-spec resolve(map(), map()) -> {ok, config()} | {error, term()}.
resolve(Application, Environment) when is_map(Application), is_map(Environment) ->
    validate(maps:merge(Application, parse_environment(Environment))).

parse_environment(Environment) ->
    maps:fold(
      fun(replication_factor, Value, Acc) ->
              Acc#{replication_factor => parse_integer(Value)};
         (seed_nodes, Value, Acc) ->
              Acc#{seed_nodes => parse_seeds(Value)};
         (Key, Value, Acc) when is_list(Value) ->
              Acc#{Key => unicode:characters_to_binary(Value)};
         (Key, Value, Acc) -> Acc#{Key => Value}
      end, #{}, Environment).

validate(#{storage_path := StoragePath0,
           node_name := NodeName,
           cluster_name := ClusterName,
           replication_factor := 3,
           seed_nodes := Seeds0}) ->
    StoragePath = filename_value(StoragePath0),
    Seeds = canonical_seeds(Seeds0),
    case {valid_absolute_path(StoragePath), valid_node_name(NodeName),
          valid_cluster_name(ClusterName), Seeds} of
        {true, true, true, {ok, CanonicalSeeds}} ->
            {ok, #{storage_path => filename:absname(StoragePath),
                   node_name => NodeName,
                   cluster_name => ClusterName,
                   replication_factor => 3,
                   seed_nodes => CanonicalSeeds}};
        {false, _, _, _} -> {error, invalid_storage_path};
        {_, false, _, _} -> {error, invalid_node_name};
        {_, _, false, _} -> {error, invalid_cluster_name};
        {_, _, _, {error, _Reason} = Error} -> Error
    end;
validate(Config) when is_map(Config) ->
    case maps:get(replication_factor, Config, undefined) of
        3 -> {error, incomplete_cluster_config};
        _ -> {error, {unsupported_replication_factor,
                      maps:get(replication_factor, Config, undefined)}}
    end.

canonical_seeds(Seeds) when is_list(Seeds) ->
    case lists:all(fun valid_node_name/1, Seeds) of
        true -> {ok, lists:usort(Seeds)};
        false -> {error, invalid_seed_nodes}
    end;
canonical_seeds(_) -> {error, invalid_seed_nodes}.

valid_node_name(Name) when is_binary(Name), byte_size(Name) > 0,
                          byte_size(Name) =< ?MAX_NAME_BYTES ->
    case re:run(Name, <<"^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$">>,
                [{capture, none}]) of
        match -> true;
        nomatch -> false
    end;
valid_node_name(_) -> false.

valid_cluster_name(Name) ->
    is_binary(Name) andalso byte_size(Name) > 0 andalso
        byte_size(Name) =< ?MAX_NAME_BYTES.

valid_absolute_path(Path) when is_list(Path); is_binary(Path) ->
    filename:pathtype(Path) =:= absolute;
valid_absolute_path(_) -> false.

filename_value(Value) when is_binary(Value) -> binary_to_list(Value);
filename_value(Value) -> Value.

parse_integer(Value) when is_list(Value) ->
    try list_to_integer(Value) catch error:badarg -> invalid end;
parse_integer(Value) when is_binary(Value) -> parse_integer(binary_to_list(Value));
parse_integer(Value) -> Value.

parse_seeds(Value) when is_list(Value) ->
    [unicode:characters_to_binary(string:trim(Seed)) ||
        Seed <- string:split(Value, ",", all), string:trim(Seed) =/= ""];
parse_seeds(Value) when is_binary(Value) -> parse_seeds(binary_to_list(Value));
parse_seeds(Value) -> Value.

getenv(Name) ->
    case os:getenv(Name) of false -> []; Value -> [Value] end.

environment_names() ->
    [{storage_path, "ERLITE_STORAGE_PATH"},
     {node_name, "ERLITE_NODE_NAME"},
     {cluster_name, "ERLITE_CLUSTER_NAME"},
     {replication_factor, "ERLITE_REPLICATION_FACTOR"},
     {seed_nodes, "ERLITE_SEED_NODES"}].
