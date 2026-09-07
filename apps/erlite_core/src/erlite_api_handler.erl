-module(erlite_api_handler).

-export([handle/4]).

-define(DEFAULT_TIMEOUT, 15000).
-define(MAX_TIMEOUT, 60000).

handle(Method, Path, Body, Identity) ->
    try route(Method, split_path(Path), Body, Identity)
    catch
        error:{badkey, Key} -> response(400, {missing_field, Key});
        error:badarg -> response(400, invalid_request)
    end.

route(<<"GET">>, [<<"v1">>, <<"health">>], _Body, _Identity) ->
    {200, #{<<"status">> => <<"ok">>}};
route(<<"GET">>, [<<"v1">>, <<"databases">>], _Body, Identity) ->
    with_auth(Identity, control, undefined,
      fun() ->
              case application:get_env(erlite_core, catalog_server) of
                  {ok, Catalog} ->
                      result(erlite_catalog:status(Catalog, ?DEFAULT_TIMEOUT,
                                                   consistent));
                  undefined -> response(503, catalog_not_configured)
              end
      end);
route(<<"POST">>, [<<"v1">>, <<"databases">>], Body, Identity) ->
    DatabaseId = maps:get(<<"database_id">>, Body),
    with_auth(Identity, control, DatabaseId,
              fun() -> result(erlite_database_lifecycle:create(DatabaseId)) end);
route(<<"DELETE">>, [<<"v1">>, <<"databases">>, DatabaseId], _Body, Identity) ->
    with_auth(Identity, control, DatabaseId,
              fun() -> result(erlite_database_lifecycle:delete(DatabaseId)) end);
route(<<"GET">>, [<<"v1">>, <<"databases">>, DatabaseId], _Body, Identity) ->
    with_auth(Identity, data, DatabaseId,
      fun() ->
              case ensure_database(DatabaseId) of
                  ok -> result(erlite_databases:status(DatabaseId));
                  Error -> result(Error)
              end
      end);
route(<<"POST">>, [<<"v1">>, <<"databases">>, DatabaseId, <<"query">>],
      Body, Identity) ->
    with_auth(Identity, data, DatabaseId,
      fun() ->
              Timeout = request_timeout(Body),
              Sql = maps:get(<<"sql">>, Body),
              Params = params(maps:get(<<"params">>, Body, [])),
              case erlite_api_query_policy:validate(Sql) of
                  ok -> query(DatabaseId, Sql, Params, Timeout);
                  Error -> result(Error)
              end
      end);
route(<<"POST">>, [<<"v1">>, <<"databases">>, DatabaseId,
                    <<"transactions">>], Body, Identity) ->
    with_auth(Identity, data, DatabaseId,
      fun() -> transaction(DatabaseId, Body) end);
route(_Method, _Path, _Body, _Identity) -> response(404, not_found).

transaction(DatabaseId, Body) ->
    TransactionId = maps:get(<<"transaction_id">>, Body),
    SchemaVersion = maps:get(<<"schema_version">>, Body, 0),
    Statements = maps:get(<<"statements">>, Body),
    Mutations = [{maps:get(<<"sql">>, Statement),
                  params(maps:get(<<"params">>, Statement, []))}
                 || Statement <- Statements],
    case erlite_raft_command:new_transaction(
           TransactionId, SchemaVersion, Mutations) of
        {ok, Command} ->
            case ensure_database(DatabaseId) of
                ok -> result(erlite_databases:write(
                               DatabaseId, Command, request_timeout(Body)));
                Error -> result(Error)
            end;
        Error -> result(Error)
    end.

query(DatabaseId, Sql, Params, Timeout) ->
    case ensure_database(DatabaseId) of
        ok -> result(erlite_databases:query(DatabaseId, Sql, Params, Timeout));
        Error -> result(Error)
    end.

ensure_database(DatabaseId) ->
    case erlite_database_router:resolve(DatabaseId, ?DEFAULT_TIMEOUT) of
        {ok, #{replicas := Replicas}} ->
            case application:get_env(erlite_core, storage_root) of
                {ok, StorageRoot} ->
                    case erlite_databases:ensure(
                           DatabaseId, #{storage_root => StorageRoot,
                                         server_ids => Replicas}) of
                        {ok, _Pid} -> ok;
                        Error -> Error
                    end;
                undefined -> {error, storage_root_not_configured}
            end;
        Error -> Error
    end.

with_auth(Identity, Action, DatabaseId, Fun) ->
    case erlite_api_auth:authorize(Identity, Action, DatabaseId) of
        ok -> Fun();
        {error, Reason} -> response(403, Reason)
    end.

request_timeout(Body) ->
    case maps:get(<<"timeout_ms">>, Body, ?DEFAULT_TIMEOUT) of
        Timeout when is_integer(Timeout), Timeout > 0, Timeout =< ?MAX_TIMEOUT ->
            Timeout;
        _ -> erlang:error(badarg)
    end.

params(Values) when is_list(Values) -> [param(Value) || Value <- Values];
params(_) -> erlang:error(badarg).
param(null) -> null;
param(Value) when is_binary(Value); is_integer(Value); is_float(Value) -> Value;
param(_) -> erlang:error(badarg).

split_path(Path) ->
    [percent_decode(Segment) || Segment <- binary:split(Path, <<"/">>, [global]),
                                Segment =/= <<>>].

percent_decode(Value) -> uri_string:percent_decode(Value).

result(ok) -> {200, #{<<"status">> => <<"ok">>}};
result({ok, Value}) -> {200, #{<<"result">> => json_value(Value)}};
result({timeout, Reason}) -> response(504, Reason);
result({error, database_not_found}) -> response(404, database_not_found);
result({error, database_exists}) -> response(409, database_exists);
result({error, Reason}) -> response(409, Reason);
result(Other) -> response(500, {unexpected_result, Other}).

response(Status, Reason) ->
    {Status, #{<<"error">> => json_value(Reason)}}.

json_value(Value) when is_binary(Value); is_integer(Value); is_float(Value);
                            Value =:= true; Value =:= false; Value =:= null -> Value;
json_value(Value) when is_atom(Value) -> atom_to_binary(Value);
json_value(Value) when is_tuple(Value) ->
    [json_value(Item) || Item <- tuple_to_list(Value)];
json_value(Value) when is_list(Value) -> [json_value(Item) || Item <- Value];
json_value(Value) when is_map(Value) ->
    maps:from_list([{json_key(Key), json_value(Item)}
                    || {Key, Item} <- maps:to_list(Value)]);
json_value(Value) -> iolist_to_binary(io_lib:format("~tp", [Value])).

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_atom(Key) -> atom_to_binary(Key);
json_key(Key) -> iolist_to_binary(io_lib:format("~tp", [Key])).
