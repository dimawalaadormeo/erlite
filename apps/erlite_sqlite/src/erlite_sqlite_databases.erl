-module(erlite_sqlite_databases).
-behaviour(gen_server).

-export([start_link/0, create/2, open/2, close/2, delete/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-type key() :: {file:filename(), binary()}.
-type state() :: #{key() => {pid(), reference()}}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec open(file:filename_all(), binary()) ->
    {ok, pid()} | {error, term()}.
open(StorageRoot, DatabaseId) ->
    gen_server:call(?MODULE, {open, StorageRoot, DatabaseId}).

-spec create(file:filename_all(), binary()) -> ok | {error, term()}.
create(StorageRoot, DatabaseId) ->
    gen_server:call(?MODULE, {create, StorageRoot, DatabaseId}, infinity).

-spec close(file:filename_all(), binary()) -> ok | {error, term()}.
close(StorageRoot, DatabaseId) ->
    gen_server:call(?MODULE, {close, StorageRoot, DatabaseId}, infinity).

-spec delete(file:filename_all(), binary()) -> ok | {error, term()}.
delete(StorageRoot, DatabaseId) ->
    gen_server:call(?MODULE, {delete, StorageRoot, DatabaseId}, infinity).

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #{}}.

handle_call({open, StorageRoot, DatabaseId}, _From, State) ->
    case database_key(StorageRoot, DatabaseId) of
        {ok, Key} -> open_key(Key, State);
        {error, _Reason} = Error -> {reply, Error, State}
    end;
handle_call({create, StorageRoot, DatabaseId}, _From, State) ->
    case database_key(StorageRoot, DatabaseId) of
        {ok, {Root, Id}} ->
            {reply, erlite_sqlite_database:create(Root, Id), State};
        {error, _Reason} = Error ->
            {reply, Error, State}
    end;
handle_call({close, StorageRoot, DatabaseId}, _From, State) ->
    case database_key(StorageRoot, DatabaseId) of
        {ok, Key} -> close_key(Key, State);
        {error, _Reason} = Error -> {reply, Error, State}
    end;
handle_call({delete, StorageRoot, DatabaseId}, _From, State) ->
    case database_key(StorageRoot, DatabaseId) of
        {ok, Key = {Root, Id}} -> delete_key(Key, Root, Id, State);
        {error, _Reason} = Error -> {reply, Error, State}
    end.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, Pid, _Reason}, State) ->
    {noreply, remove_owner(Pid, Monitor, State)};
handle_info(_Info, State) ->
    {noreply, State}.

database_key(StorageRoot, DatabaseId) ->
    case erlite_sqlite_database:path(StorageRoot, DatabaseId) of
        {ok, Path} -> {ok, {filename:dirname(Path), DatabaseId}};
        {error, _Reason} = Error -> Error
    end.

open_key(Key = {StorageRoot, DatabaseId}, State) ->
    case maps:get(Key, State, undefined) of
        {Pid, _Monitor} when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {reply, {ok, Pid}, State};
                false -> start_owner(Key, StorageRoot, DatabaseId, maps:remove(Key, State))
            end;
        undefined ->
            start_owner(Key, StorageRoot, DatabaseId, State)
    end.

start_owner(Key, StorageRoot, DatabaseId, State) ->
    case erlite_sqlite_database_sup:start_owner(StorageRoot, DatabaseId) of
        {ok, Pid} ->
            Monitor = erlang:monitor(process, Pid),
            {reply, {ok, Pid}, State#{Key => {Pid, Monitor}}};
        {error, {Reason, ChildSpec}}
          when is_tuple(ChildSpec), element(1, ChildSpec) =:= child ->
            {reply, normalize_start_error(Reason), State};
        {error, _Reason} = Error ->
            {reply, Error, State}
    end.

close_key(Key, State) ->
    case maps:get(Key, State, undefined) of
        {Pid, Monitor} ->
            case stop_owner(Pid) of
                ok ->
                    erlang:demonitor(Monitor, [flush]),
                    {reply, ok, maps:remove(Key, State)};
                {error, _Reason} = Error ->
                    {reply, Error, State}
            end;
        undefined ->
            {reply, ok, State}
    end.

delete_key(Key, StorageRoot, DatabaseId, State) ->
    case maps:get(Key, State, undefined) of
        {Pid, Monitor} ->
            case stop_owner(Pid) of
                ok ->
                    erlang:demonitor(Monitor, [flush]),
                    {reply, erlite_sqlite_database:delete(StorageRoot, DatabaseId),
                     maps:remove(Key, State)};
                {error, _Reason} = Error ->
                    {reply, Error, State}
            end;
        undefined ->
            {reply, erlite_sqlite_database:delete(StorageRoot, DatabaseId), State}
    end.

stop_owner(Pid) ->
    try erlite_sqlite_owner:close(Pid) of
        ok -> ok
    catch
        exit:noproc -> ok;
        exit:{noproc, _Call} -> ok;
        exit:Reason -> {error, {owner_stop_failed, Reason}}
    end.

normalize_start_error({shutdown, Reason}) ->
    {error, Reason};
normalize_start_error(Reason) ->
    {error, Reason}.

remove_owner(Pid, Monitor, State) ->
    maps:filter(
      fun(_Key, {OwnerPid, OwnerMonitor}) ->
              OwnerPid =/= Pid orelse OwnerMonitor =/= Monitor
      end,
      State).
