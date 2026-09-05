-module(erlite_core_app_tests).

-include_lib("eunit/include/eunit.hrl").

supervisor_starts_with_no_children_test() ->
    {ok, Pid} = erlite_core_sup:start_link(),
    unlink(Pid),
    ?assertEqual([], supervisor:which_children(Pid)),
    ok = gen_server:stop(Pid).

application_callback_starts_supervisor_test() ->
    {ok, Pid} = erlite_core_app:start(normal, []),
    unlink(Pid),
    ?assertEqual(Pid, whereis(erlite_core_sup)),
    ok = gen_server:stop(Pid),
    ?assertEqual(ok, erlite_core_app:stop(undefined)).

