-module(erlite_api_server).
-behaviour(gen_server).

-export([start_link/0, configure/1, port/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_HEADER_BYTES, 16384).
-define(MAX_BODY_BYTES, 1048576).
-define(RECV_TIMEOUT, 15000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
configure(Config) -> gen_server:call(?MODULE, {configure, Config}, infinity).
port() -> gen_server:call(?MODULE, port).

init([]) ->
    process_flag(trap_exit, true),
    case application:get_env(erlite_core, api) of
        {ok, Config = #{enabled := true}} -> start_listener(Config, #{});
        _ -> {ok, #{}}
    end.

handle_call({configure, Config}, _From, State) ->
    close_listener(State),
    case start_listener(Config, #{}) of
        {ok, NewState} ->
            ok = application:set_env(erlite_core, api, Config),
            {reply, ok, NewState};
        {stop, Reason} -> {reply, {error, Reason}, #{}}
    end;
handle_call(port, _From, State = #{listen_socket := ListenSocket}) ->
    {ok, {_Address, Port}} = ssl:sockname(ListenSocket),
    {reply, {ok, Port}, State};
handle_call(port, _From, State) -> {reply, {error, api_disabled}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Request, State) -> {noreply, State}.

handle_info({'EXIT', Acceptor, _Reason}, State = #{acceptor := Acceptor}) ->
    NewAcceptor = spawn_link(fun() -> accept_loop(
                                       maps:get(listen_socket, State),
                                       maps:get(credentials, State)) end),
    {noreply, State#{acceptor => NewAcceptor}};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) -> close_listener(State).

start_listener(#{enabled := true, port := Port,
                 credentials := Credentials} = Config, _State)
  when is_integer(Port), Port >= 0, Port =< 65535,
       is_list(Credentials), Credentials =/= [] ->
    case erlite_api_auth:valid_credentials(Credentials) of
        true -> open_listener(Config, Port, Credentials);
        false -> {stop, invalid_credentials_config}
    end;
start_listener(#{enabled := false}, _State) -> {ok, #{}};
start_listener(_Config, _State) -> {stop, invalid_api_config}.

open_listener(Config, Port, Credentials) ->
    ok = ensure_ssl_started(),
    Options = tls_credentials(Config) ++ [binary,
               {active, false}, {reuseaddr, true},
               {versions, ['tlsv1.2', 'tlsv1.3']}],
    case ssl:listen(Port, Options) of
        {ok, ListenSocket} ->
            Acceptor = spawn_link(fun() -> accept_loop(ListenSocket,
                                                       Credentials) end),
            {ok, #{listen_socket => ListenSocket, acceptor => Acceptor,
                   credentials => Credentials}};
        {error, Reason} -> {stop, {tls_listen_failed, Reason}}
    end.

tls_credentials(#{certfile := CertFile, keyfile := KeyFile})
  when is_list(CertFile), is_list(KeyFile) ->
    [{certfile, CertFile}, {keyfile, KeyFile}];
tls_credentials(#{cert := Certificate, key := PrivateKey})
  when is_binary(Certificate), is_tuple(PrivateKey) ->
    [{cert, Certificate}, {key, PrivateKey}];
tls_credentials(_) -> erlang:error(invalid_tls_credentials).

ensure_ssl_started() ->
    case application:ensure_all_started(ssl) of
        {ok, _} -> ok;
        {error, {ssl, {already_started, ssl}}} -> ok;
        {error, Reason} -> erlang:error({ssl_start_failed, Reason})
    end.

close_listener(#{listen_socket := ListenSocket}) ->
    ssl:close(ListenSocket),
    ok;
close_listener(_) -> ok.

accept_loop(ListenSocket, Credentials) ->
    case ssl:transport_accept(ListenSocket) of
        {ok, Socket} ->
            Pid = spawn(fun() -> connection_wait(Credentials) end),
            ok = ssl:controlling_process(Socket, Pid),
            Pid ! {socket, Socket},
            accept_loop(ListenSocket, Credentials);
        {error, closed} -> ok;
        {error, _Reason} -> accept_loop(ListenSocket, Credentials)
    end.

connection_wait(Credentials) ->
    receive {socket, Socket} -> serve(Socket, Credentials) end.

serve(Socket, Credentials) ->
    Result = case ssl:handshake(Socket, ?RECV_TIMEOUT) of
                 {ok, TlsSocket} -> receive_request(TlsSocket, Credentials);
                 {error, _} -> ok
             end,
    _ = ssl:close(Socket),
    Result.

receive_request(Socket, Credentials) ->
    case recv_headers(Socket, <<>>) of
        {ok, HeaderBlock, Rest} ->
            handle_request(Socket, HeaderBlock, Rest, Credentials);
        {error, request_too_large} -> send_response(Socket, 413, error_body(request_too_large));
        {error, _} -> send_response(Socket, 400, error_body(invalid_request))
    end.

recv_headers(_Socket, Data) when byte_size(Data) > ?MAX_HEADER_BYTES ->
    {error, request_too_large};
recv_headers(Socket, Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Headers, Rest] -> {ok, Headers, Rest};
        [_] ->
            case ssl:recv(Socket, 0, ?RECV_TIMEOUT) of
                {ok, Chunk} -> recv_headers(Socket, <<Data/binary, Chunk/binary>>);
                Error -> Error
            end
    end.

handle_request(Socket, HeaderBlock, Rest, Credentials) ->
    try handle_request_checked(Socket, HeaderBlock, Rest, Credentials)
    catch
        _:_ -> send_response(Socket, 400, error_body(invalid_request))
    end.

handle_request_checked(Socket, HeaderBlock, Rest, Credentials) ->
    case parse_headers(HeaderBlock) of
        {ok, Method, Path, Headers} ->
            case request_body_length(Headers) of
                {ok, Length} when Length =< ?MAX_BODY_BYTES ->
                    case recv_body(Socket, Rest, Length) of
                        {ok, BodyBinary} -> dispatch(
                                              Socket, Method, Path, Headers,
                                              BodyBinary, Credentials);
                        _ -> send_response(Socket, 400, error_body(invalid_body))
                    end;
                {ok, _Length} ->
                    send_response(Socket, 413, error_body(request_too_large));
                {error, _} ->
                    send_response(Socket, 400, error_body(invalid_request))
            end;
        {error, _} -> send_response(Socket, 400, error_body(invalid_request))
    end.

parse_headers(HeaderBlock) ->
    case binary:split(HeaderBlock, <<"\r\n">>, [global]) of
        [RequestLine | HeaderLines] ->
            case binary:split(RequestLine, <<" ">>, [global]) of
                [Method, Path, <<"HTTP/1.1">>] ->
                    case header_map(HeaderLines, #{}) of
                        {ok, Headers} ->
                            {ok, Method, path_without_query(Path), Headers};
                        {error, _} = Error -> Error
                    end;
                _ -> {error, invalid_request_line}
            end;
        _ -> {error, invalid_headers}
    end.

header_map([], Headers) -> {ok, Headers};
header_map([Line | Rest], Headers) ->
    case binary:split(Line, <<":">>) of
        [RawName, Value] ->
            Name = lower(trim(RawName)),
            case Name =/= <<>> andalso not maps:is_key(Name, Headers) of
                true -> header_map(Rest, Headers#{Name => trim(Value)});
                false -> {error, invalid_header}
            end;
        _ -> {error, invalid_header}
    end.

request_body_length(Headers) ->
    case maps:is_key(<<"transfer-encoding">>, Headers) of
        true -> {error, unsupported_transfer_encoding};
        false -> content_length(Headers)
    end.

content_length(Headers) ->
    Value = maps:get(<<"content-length">>, Headers, <<"0">>),
    try binary_to_integer(Value) of
        Length when Length >= 0 -> {ok, Length};
        _ -> {error, invalid_content_length}
    catch
        error:badarg -> {error, invalid_content_length}
    end.

recv_body(_Socket, Data, Length) when byte_size(Data) >= Length ->
    {ok, binary:part(Data, 0, Length)};
recv_body(Socket, Data, Length) ->
    case ssl:recv(Socket, Length - byte_size(Data), ?RECV_TIMEOUT) of
        {ok, Chunk} -> recv_body(Socket, <<Data/binary, Chunk/binary>>, Length);
        Error -> Error
    end.

dispatch(Socket, Method, Path, Headers, BodyBinary, Credentials) ->
    case identity(Path, Headers, Credentials) of
        {ok, Identity} ->
            case decode_body(BodyBinary) of
                {ok, Body} ->
                    {Status, Response} = erlite_api_handler:handle(
                                           Method, Path, Body, Identity),
                    send_response(Socket, Status, Response);
                {error, _} -> send_response(Socket, 400, error_body(invalid_json))
            end;
        {error, Reason} -> send_response(Socket, 401, error_body(Reason))
    end.

identity(<<"/v1/health">>, _Headers, _Credentials) ->
    {ok, #{role => service, databases => []}};
identity(_Path, Headers, Credentials) ->
    Token = case maps:get(<<"authorization">>, Headers, undefined) of
                <<"Bearer ", Value/binary>> -> Value;
                _ -> undefined
            end,
    erlite_api_auth:authenticate(Token, Credentials).

decode_body(<<>>) -> {ok, #{}};
decode_body(Binary) ->
    try json:decode(Binary) of
        Map when is_map(Map) -> {ok, Map};
        _ -> {error, body_must_be_object}
    catch _:_ -> {error, invalid_json}
    end.

send_response(Socket, Status, Body) ->
    Encoded = iolist_to_binary(json:encode(Body)),
    Response = [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>,
                reason(Status), <<"\r\nContent-Type: application/json\r\n">>,
                <<"Cache-Control: no-store\r\nConnection: close\r\n">>,
                <<"Content-Length: ">>, integer_to_binary(byte_size(Encoded)),
                <<"\r\n\r\n">>, Encoded],
    ssl:send(Socket, Response).

error_body(Reason) -> #{<<"error">> => atom_to_binary(Reason)}.
path_without_query(Path) -> hd(binary:split(Path, <<"?">>)).
lower(Value) -> string:lowercase(Value).
trim(Value) -> string:trim(Value).

reason(200) -> <<"OK">>;
reason(400) -> <<"Bad Request">>;
reason(401) -> <<"Unauthorized">>;
reason(403) -> <<"Forbidden">>;
reason(404) -> <<"Not Found">>;
reason(409) -> <<"Conflict">>;
reason(413) -> <<"Content Too Large">>;
reason(500) -> <<"Internal Server Error">>;
reason(503) -> <<"Service Unavailable">>;
reason(504) -> <<"Gateway Timeout">>;
reason(_) -> <<"Error">>.
