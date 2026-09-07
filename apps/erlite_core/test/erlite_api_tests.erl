-module(erlite_api_tests).

-include_lib("eunit/include/eunit.hrl").

authorization_is_database_scoped_test() ->
    Token = <<"01234567890123456789012345678901">>,
    Credentials = [#{token => Token, role => service,
                     databases => [<<"allowed">>]}],
    {ok, Identity} = erlite_api_auth:authenticate(Token, Credentials),
    ok = erlite_api_auth:authorize(Identity, data, <<"allowed">>),
    ?assertEqual({error, database_forbidden},
                 erlite_api_auth:authorize(Identity, data, <<"other">>)),
    ?assertEqual({error, admin_required},
                 erlite_api_auth:authorize(Identity, control, <<"allowed">>)),
    ?assertEqual({error, invalid_bearer_token},
                 erlite_api_auth:authenticate(
                   <<"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx">>, Credentials)).

admin_can_use_control_api_test() ->
    Token = <<"abcdefghijklmnopqrstuvwxyzABCDEF">>,
    {ok, Identity} = erlite_api_auth:authenticate(
                       Token, [#{token => Token, role => admin}]),
    ?assertEqual(ok, erlite_api_auth:authorize(Identity, control, undefined)),
    ?assertEqual(ok, erlite_api_auth:authorize(Identity, data, <<"any">>)).

handler_rejects_service_control_and_bad_timeout_test() ->
    Service = #{role => service, databases => [<<"db">>]},
    {403, _} = erlite_api_handler:handle(
                 <<"POST">>, <<"/v1/databases">>,
                 #{<<"database_id">> => <<"db">>}, Service),
    {400, _} = erlite_api_handler:handle(
                 <<"POST">>, <<"/v1/databases/db/query">>,
                 #{<<"sql">> => <<"SELECT 1">>,
                   <<"timeout_ms">> => 60001}, Service).

query_policy_is_read_only_and_hides_internal_tables_test() ->
    ?assertEqual(ok, erlite_api_query_policy:validate(
                       <<"SELECT name FROM products WHERE sku = ?">>)),
    ?assertEqual({error, unsafe_query},
                 erlite_api_query_policy:validate(
                   <<"SELECT * FROM __erlite_replica_metadata">>)),
    ?assertEqual({error, unsafe_query},
                 erlite_api_query_policy:validate(
                   <<"SELECT 1; DELETE FROM products">>)),
    ?assertEqual({error, unsafe_query},
                 erlite_api_query_policy:validate(
                   <<"PRAGMA integrity_check">>)).

tls_listener_requires_auth_test_() ->
    {timeout, 30, fun tls_listener_requires_auth/0}.

tls_listener_requires_auth() ->
    application:ensure_all_started(ssl),
    Chain = #{root => [{digest, sha256}, {key, {rsa, 2048, 65537}}],
              peer => [{digest, sha256}, {key, {rsa, 2048, 65537}}]},
    TestData = public_key:pkix_test_data(
                 #{server_chain => Chain, client_chain => Chain}),
    ServerOptions = maps:get(server_config, TestData),
    Certificate = proplists:get_value(cert, ServerOptions),
    PrivateKey = proplists:get_value(key, ServerOptions),
    Token = <<"01234567890123456789012345678901">>,
    {ok, Server} = erlite_api_server:start_link(),
    unlink(Server),
    try
        ok = erlite_api_server:configure(
               #{enabled => true, port => 0, cert => Certificate,
                 key => PrivateKey,
                 credentials => [#{token => Token, role => admin}]}),
        {ok, Port} = erlite_api_server:port(),
        assert_status(Port,
                      <<"GET /v1/databases HTTP/1.1\r\nHost: localhost\r\n"
                        "Connection: close\r\n\r\n">>, 401),
        assert_status(Port,
                      <<"POST /v1/databases HTTP/1.1\r\nHost: localhost\r\n"
                        "Content-Length: nope\r\n\r\n">>, 400),
        assert_status(Port,
                      <<"POST /v1/databases HTTP/1.1\r\nHost: localhost\r\n"
                        "Content-Length: -1\r\n\r\n">>, 400),
        assert_status(Port,
                      <<"GET /v1/databases HTTP/1.1\r\nHost: localhost\r\n"
                        "not-a-header\r\n\r\n">>, 400),
        assert_status(Port,
                      <<"POST /v1/databases HTTP/1.1\r\nHost: localhost\r\n"
                        "Transfer-Encoding: chunked\r\n\r\n">>, 400)
    after
        gen_server:stop(Server),
        application:unset_env(erlite_core, api)
    end.

assert_status(Port, Request, Status) ->
    {ok, Socket} = ssl:connect(
                     "localhost", Port,
                     [binary, {verify, verify_none}, {active, false}], 10000),
    ok = ssl:send(Socket, Request),
    {ok, Response} = recv_all(Socket, <<>>),
    Expected = <<"HTTP/1.1 ", (integer_to_binary(Status))/binary>>,
    ?assertMatch({0, _}, binary:match(Response, Expected)).

recv_all(Socket, Acc) ->
    case ssl:recv(Socket, 0, 10000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> {ok, Acc};
        Error -> Error
    end.
