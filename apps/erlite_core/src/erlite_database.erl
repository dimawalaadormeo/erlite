-module(erlite_database).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RPC_TIMEOUT, 15000).

start_link(DatabaseId, Options) ->
    gen_server:start_link(?MODULE, {DatabaseId, Options}, []).

init({DatabaseId, #{storage_root := StorageRoot,
                    server_ids := ServerIds} = Options}) ->
    case open_replicas(StorageRoot, DatabaseId, ServerIds) of
        {ok, Replicas, Roots, RuntimeIdentity} ->
            ClusterName = cluster_name(DatabaseId),
            case erlite_raft_cluster:start(
                   ClusterName, ServerIds, RuntimeIdentity) of
                {ok, _Started, []} ->
                    {ok, #{database_id => DatabaseId,
                           storage_root => StorageRoot,
                           server_ids => ServerIds,
                           replicas => Replicas,
                           replica_roots => Roots,
                           runtime_identity => RuntimeIdentity,
                           mode => active,
                           timeout => maps:get(timeout, Options, 15000)}};
                Error ->
                    close_replicas(DatabaseId, Roots),
                    {stop, Error}
            end;
        {error, _Reason} = Error -> {stop, Error}
    end;
init({_DatabaseId, _Options}) -> {stop, invalid_database_options}.

handle_call(status, _From, State) ->
    {reply, {ok, database_status(State)}, State};
handle_call(registry_metadata, _From,
            State = #{database_id := DatabaseId, server_ids := ServerIds}) ->
    {reply, {ok, #{database_id => DatabaseId, server_ids => ServerIds}}, State};
handle_call(cool, _From, State = #{mode := cold}) ->
    {reply, ok, State};
handle_call(cool, _From, State = #{database_id := DatabaseId,
                                   replica_roots := Roots}) ->
    ok = close_replicas(DatabaseId, Roots),
    {reply, ok, State#{mode => cold, replicas => #{}}};
handle_call({write, Command, Timeout}, _From, State0) ->
    with_active(State0,
      fun(State = #{server_ids := ServerIds, replicas := Replicas}) ->
              {erlite_raft_database:write(ServerIds, Command, Replicas, Timeout),
               State}
      end);
handle_call({query, Sql, Params, Timeout}, _From, State0) ->
    with_active(State0,
      fun(State = #{server_ids := ServerIds, replicas := Replicas}) ->
              {erlite_raft_database:consistent_read(
                 ServerIds, Sql, Params, Replicas, Timeout), State}
      end);
handle_call(delete, _From, State = #{database_id := DatabaseId,
                                     server_ids := ServerIds,
                                     replica_roots := Roots}) ->
    stop_servers(ServerIds),
    ok = close_replicas(DatabaseId, Roots),
    Reply = delete_replicas(DatabaseId, Roots),
    {stop, normal, Reply, State}.

handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.

with_active(State0, Operation) ->
    case activate(State0) of
        {ok, State} ->
            {Reply, NewState} = Operation(State),
            {reply, Reply, NewState};
        {error, Reason} -> {reply, {error, Reason}, State0}
    end.

activate(State = #{mode := active}) -> {ok, State};
activate(State = #{database_id := DatabaseId,
                   replica_roots := Roots,
                   runtime_identity := Expected}) ->
    case reopen_replicas(DatabaseId, maps:to_list(Roots), Expected, #{}) of
        {ok, Replicas} -> {ok, State#{mode => active, replicas => Replicas}};
        {error, _Reason} = Error -> Error
    end.

open_replicas(StorageRoot, DatabaseId, ServerIds) ->
    Roots = maps:from_list(
              [{ServerId, filename:join(
                            [StorageRoot, "replicas", integer_to_list(N)])}
               || {ServerId, N} <- lists:zip(ServerIds, [1, 2, 3])]),
    case create_and_open(DatabaseId, maps:to_list(Roots), #{}, undefined, #{}) of
        {ok, Replicas, RuntimeIdentity} ->
            {ok, Replicas, Roots, RuntimeIdentity};
        {error, Reason, CreatedRoots} ->
            close_replicas(DatabaseId, CreatedRoots),
            delete_replicas(DatabaseId, CreatedRoots),
            {error, Reason}
    end.

create_and_open(_DatabaseId, [], Replicas, RuntimeIdentity, _CreatedRoots) ->
    {ok, Replicas, RuntimeIdentity};
create_and_open(DatabaseId, [{ServerId, Root} | Rest], Replicas, Expected,
                CreatedRoots) ->
    case member_call(ServerId, erlite_sqlite_databases, create,
                     [Root, DatabaseId]) of
        ok ->
            NewCreated = CreatedRoots#{ServerId => Root},
            open_created(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
                         NewCreated);
        {error, database_exists} -> {error, database_exists, CreatedRoots};
        {error, Reason} -> {error, Reason, CreatedRoots}
    end.

open_created(DatabaseId, ServerId, Root, Rest, Replicas, Expected,
             CreatedRoots) ->
    case member_call(ServerId, erlite_sqlite_databases, open,
                     [Root, DatabaseId]) of
        {ok, Owner} ->
            case erlite_sqlite_owner:runtime_identity(Owner) of
                {ok, Identity} when Expected =:= undefined; Identity =:= Expected ->
                    create_and_open(DatabaseId, Rest,
                                    Replicas#{ServerId => Owner}, Identity,
                                    CreatedRoots);
                {ok, _Different} ->
                    {error, incompatible_sqlite_runtime, CreatedRoots};
                {error, Reason} -> {error, Reason, CreatedRoots}
            end;
        {error, Reason} -> {error, Reason, CreatedRoots}
    end.

reopen_replicas(_DatabaseId, [], _Expected, Replicas) -> {ok, Replicas};
reopen_replicas(DatabaseId, [{ServerId, Root} | Rest], Expected, Replicas) ->
    case member_call(ServerId, erlite_sqlite_databases, open, [Root, DatabaseId]) of
        {ok, Owner} ->
            case erlite_sqlite_owner:verify_runtime(Owner, Expected) of
                ok -> reopen_replicas(DatabaseId, Rest, Expected,
                                      Replicas#{ServerId => Owner});
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

database_status(#{database_id := DatabaseId, mode := Mode,
                  server_ids := ServerIds, replicas := Replicas,
                  replica_roots := Roots}) ->
    #{database_id => DatabaseId, mode => Mode,
      raft_members => length(ServerIds),
      open_sqlite_replicas => map_size(Replicas),
      controller_memory_bytes => process_memory(node(), self()),
      sqlite_owner_memory_bytes => lists:sum(
                                     [process_memory(
                                        element(2, ServerId), Owner)
                                      || {ServerId, Owner} <-
                                             maps:to_list(Replicas)]),
      raft_server_memory_bytes => lists:sum(
                                    [raft_server_memory(ServerId)
                                     || ServerId <- ServerIds]),
      sqlite_bytes => lists:sum(
                        [file_size(ServerId, Root, DatabaseId)
                         || {ServerId, Root} <- maps:to_list(Roots)])}.

file_size(ServerId, Root, DatabaseId) ->
    case member_call(ServerId, erlite_sqlite_database, path, [Root, DatabaseId]) of
        {ok, Path} ->
            case member_call(ServerId, filelib, file_size, [Path]) of
                Size when is_integer(Size) -> Size;
                _ -> 0
            end;
        _ -> 0
    end.

raft_server_memory({Name, Node}) ->
    case member_call({Name, Node}, ra_directory, where_is, [default, Name]) of
        Pid when is_pid(Pid) -> process_memory(Node, Pid);
        _ -> 0
    end.

process_memory(Node, Pid) when Node =:= node() ->
    case process_info(Pid, memory) of
        {memory, Bytes} -> Bytes;
        undefined -> 0
    end;
process_memory(Node, Pid) ->
    case rpc:call(Node, erlang, process_info, [Pid, memory]) of
        {memory, Bytes} -> Bytes;
        _ -> 0
    end.

close_replicas(DatabaseId, Roots) ->
    lists:foreach(fun({ServerId, Root}) ->
                          _ = member_call(ServerId, erlite_sqlite_databases,
                                          close, [Root, DatabaseId])
                  end, maps:to_list(Roots)),
    ok.

delete_replicas(DatabaseId, Roots) ->
    Results = [member_call(ServerId, erlite_sqlite_databases, delete,
                           [Root, DatabaseId])
               || {ServerId, Root} <- maps:to_list(Roots)],
    case [Error || Error = {error, _} <- Results] of
        [] -> ok;
        [Error | _] -> Error
    end.

stop_servers(ServerIds) ->
    lists:foreach(fun(ServerId) ->
                          _ = member_call(ServerId, ra, force_delete_server,
                                          [default, ServerId])
                  end, ServerIds).

member_call({_, Node}, Module, Function, Arguments) when Node =:= node() ->
    erlang:apply(Module, Function, Arguments);
member_call({_, Node}, Module, Function, Arguments) ->
    case rpc:call(Node, Module, Function, Arguments, ?RPC_TIMEOUT) of
        {badrpc, Reason} -> {error, {replica_rpc_failed, Node, Reason}};
        Result -> Result
    end.

cluster_name(DatabaseId) ->
    <<"erlite-db-", (binary:encode_hex(
                       crypto:hash(sha256, DatabaseId), lowercase))/binary>>.
