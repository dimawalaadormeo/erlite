-module(erlite_cluster_config_tests).

-include_lib("eunit/include/eunit.hrl").

valid_config_is_canonicalized_test() ->
    {ok, Config} = erlite_cluster_config:resolve(base(), #{}),
    ?assertEqual([<<"erlite@a">>, <<"erlite@b">>],
                 maps:get(seed_nodes, Config)),
    ?assertEqual(3, maps:get(replication_factor, Config)).

environment_values_override_application_config_test() ->
    Environment = #{storage_path => "/srv/erlite",
                    node_name => "erlite@override",
                    cluster_name => "staging",
                    replication_factor => "3",
                    seed_nodes => "erlite@c, erlite@b"},
    {ok, Config} = erlite_cluster_config:resolve(base(), Environment),
    ?assertEqual("/srv/erlite", maps:get(storage_path, Config)),
    ?assertEqual(<<"erlite@override">>, maps:get(node_name, Config)),
    ?assertEqual([<<"erlite@b">>, <<"erlite@c">>],
                 maps:get(seed_nodes, Config)).

invalid_node_and_seed_names_are_rejected_test() ->
    ?assertEqual({error, invalid_node_name},
                 erlite_cluster_config:resolve(
                   (base())#{node_name => <<"missing-at-sign">>}, #{})),
    ?assertEqual({error, invalid_seed_nodes},
                 erlite_cluster_config:resolve(
                   (base())#{seed_nodes => [<<"bad seed">>]}, #{})).

phase_two_requires_rf_three_test() ->
    ?assertEqual({error, {unsupported_replication_factor, 2}},
                 erlite_cluster_config:resolve(
                   (base())#{replication_factor => 2}, #{})).

incomplete_and_relative_config_are_rejected_test() ->
    ?assertEqual({error, incomplete_cluster_config},
                 erlite_cluster_config:resolve(
                   maps:remove(node_name, base()), #{})),
    ?assertEqual({error, invalid_storage_path},
                 erlite_cluster_config:resolve(
                   (base())#{storage_path => "relative"}, #{})).

base() ->
    #{storage_path => "/var/lib/erlite",
      node_name => <<"erlite@a">>,
      cluster_name => <<"production">>,
      replication_factor => 3,
      seed_nodes => [<<"erlite@b">>, <<"erlite@a">>, <<"erlite@b">>]}.
