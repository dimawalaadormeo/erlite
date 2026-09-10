-module(erlite_release).

-export([metadata/0, compatible/2]).

-ifdef(TEST).
-export([set_test_metadata/1, clear_test_metadata/0]).
-endif.

-define(CLUSTER_PROTOCOL, 1).
-define(MIN_CLUSTER_PROTOCOL, 1).
-define(COMMAND_FORMAT, 1).
-define(SNAPSHOT_FORMAT, 2).

metadata() ->
    case test_metadata() of
        undefined -> current_metadata();
        Metadata -> Metadata
    end.

current_metadata() ->
    #{cluster_protocol => ?CLUSTER_PROTOCOL,
      min_cluster_protocol => ?MIN_CLUSTER_PROTOCOL,
      command_format => ?COMMAND_FORMAT,
      snapshot_format => ?SNAPSHOT_FORMAT,
      otp_release => list_to_binary(erlang:system_info(otp_release)),
      sqlite_runtime => sqlite_runtime()}.

-ifdef(TEST).
set_test_metadata(Metadata) when is_map(Metadata) ->
    persistent_term:put({?MODULE, test_metadata}, Metadata),
    ok.
clear_test_metadata() ->
    persistent_term:erase({?MODULE, test_metadata}),
    ok.
test_metadata() -> persistent_term:get({?MODULE, test_metadata}, undefined).
-else.
test_metadata() -> undefined.
-endif.

compatible(Local, Remote) when is_map(Local), is_map(Remote) ->
    Required = [cluster_protocol, min_cluster_protocol, command_format,
                snapshot_format, sqlite_runtime],
    case lists:all(fun(Key) -> maps:is_key(Key, Local) andalso
                               maps:is_key(Key, Remote) end, Required) of
        false -> {error, incomplete_release_metadata};
        true -> compatible_metadata(Local, Remote)
    end;
compatible(_, _) -> {error, invalid_release_metadata}.

compatible_metadata(Local, Remote) ->
    LocalProtocol = maps:get(cluster_protocol, Local),
    RemoteProtocol = maps:get(cluster_protocol, Remote),
    ProtocolOverlap = LocalProtocol >= maps:get(min_cluster_protocol, Remote)
        andalso RemoteProtocol >= maps:get(min_cluster_protocol, Local),
    ExactFormats = maps:get(command_format, Local) =:=
                       maps:get(command_format, Remote)
        andalso maps:get(snapshot_format, Local) =:=
                    maps:get(snapshot_format, Remote),
    SameSqlite = maps:get(sqlite_runtime, Local) =:=
                     maps:get(sqlite_runtime, Remote),
    case {ProtocolOverlap, ExactFormats, SameSqlite} of
        {true, true, true} -> ok;
        {false, _, _} -> {error, incompatible_cluster_protocol};
        {_, false, _} -> {error, incompatible_storage_format};
        {_, _, false} -> {error, incompatible_sqlite_runtime}
    end.

sqlite_runtime() ->
    case erlite_sqlite:open(":memory:") of
        {ok, Connection} ->
            Result = erlite_sqlite_compatibility:runtime_identity(Connection),
            _ = erlite_sqlite:close(Connection),
            case Result of {ok, Identity} -> Identity; _ -> unavailable end;
        _ -> unavailable
    end.
