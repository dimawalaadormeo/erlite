-module(erlite_release_tests).

-include_lib("eunit/include/eunit.hrl").

current_release_is_self_compatible_test() ->
    Metadata = erlite_release:metadata(),
    ?assertEqual(ok, erlite_release:compatible(Metadata, Metadata)).

rolling_upgrade_rejects_protocol_gap_test() ->
    Local = erlite_release:metadata(),
    Future = Local#{cluster_protocol => 3, min_cluster_protocol => 2},
    ?assertEqual({error, incompatible_cluster_protocol},
                 erlite_release:compatible(Local, Future)).

rolling_upgrade_rejects_durable_format_change_test() ->
    Local = erlite_release:metadata(),
    Future = Local#{snapshot_format => maps:get(snapshot_format, Local) + 1},
    ?assertEqual({error, incompatible_storage_format},
                 erlite_release:compatible(Local, Future)).

rolling_upgrade_rejects_sqlite_runtime_change_test() ->
    Local = erlite_release:metadata(),
    Future = Local#{sqlite_runtime => different},
    ?assertEqual({error, incompatible_sqlite_runtime},
                 erlite_release:compatible(Local, Future)).
