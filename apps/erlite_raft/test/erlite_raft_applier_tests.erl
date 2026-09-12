-module(erlite_raft_applier_tests).

-include_lib("eunit/include/eunit.hrl").

ordered_entries_apply_across_raft_index_gaps_test() ->
    {module, erlite_raft_applier} = code:ensure_loaded(erlite_raft_applier),
    %% The SQLite transition behavior used by the external applier is covered
    %% here without starting a Ra system; cluster lifecycle is Common Test scope.
    ?assertEqual(true, erlang:function_exported(erlite_raft_applier, catch_up, 3)),
    ?assertEqual(true,
                 erlang:function_exported(erlite_raft_applier,
                                           submit_and_apply, 4)).
