-module(erlite_core_app_tests).

-include_lib("eunit/include/eunit.hrl").

supervisor_starts_database_lifecycle_children_test() ->
    {ok, Pid} = erlite_core_sup:start_link(),
    unlink(Pid),
    Children = supervisor:which_children(Pid),
    ?assertEqual([erlite_api_server, erlite_database_lifecycle,
                  erlite_database_router, erlite_database_sup,
                  erlite_databases, erlite_replica_repair],
                 lists:sort([Id || {Id, _, _, _} <- Children])),
    ok = gen_server:stop(Pid).

application_callback_starts_supervisor_test() ->
    {ok, Pid} = erlite_core_app:start(normal, []),
    unlink(Pid),
    ?assertEqual(Pid, whereis(erlite_core_sup)),
    ok = gen_server:stop(Pid),
    ?assertEqual(ok, erlite_core_app:stop(undefined)).
