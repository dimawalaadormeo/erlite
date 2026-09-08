-module(erlite_fleet_migrations).
-behaviour(gen_server).

-export([start_link/0, configure/1, start/3, run_batch/1, pause/1, resume/1,
         status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TIMEOUT, 15000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
configure(Catalog) -> gen_server:call(?MODULE, {configure, Catalog}).
start(Set, Migrations, Options) ->
    gen_server:call(?MODULE, {start, Set, Migrations, Options}, infinity).
run_batch(Id) -> gen_server:call(?MODULE, {run_batch, Id}, infinity).
pause(Id) -> gen_server:call(?MODULE, {state, Id, paused}).
resume(Id) -> gen_server:call(?MODULE, {state, Id, running}).
status(Id) -> gen_server:call(?MODULE, {status, Id}).

init([]) ->
    {ok, case application:get_env(erlite_core, catalog_server) of
             {ok, Catalog} -> #{catalog => Catalog};
             _ -> #{}
         end}.

handle_call({configure, Catalog}, _From, _State) ->
    {reply, ok, #{catalog => Catalog}};
handle_call({start, Set, Migrations, Options}, _From,
            State = #{catalog := Catalog}) ->
    Reply = case validate_set(Set, Migrations, Options) of
        {ok, Canonical} ->
            Key = maps:get(idempotency_key, Canonical),
            Id = campaign_id(Set, Key),
            Campaign = Canonical#{campaign_id => Id, migration_set => Set},
            case erlite_catalog:create_migration_campaign(
                   Catalog, Campaign, ?TIMEOUT) of
                ok -> {ok, Id};
                Error -> Error
            end;
        Error -> Error
    end,
    {reply, Reply, State};
handle_call({run_batch, Id}, _From, State = #{catalog := Catalog}) ->
    {reply, run_batch(Id, Catalog), State};
handle_call({state, Id, Status}, _From, State = #{catalog := Catalog}) ->
    {reply, erlite_catalog:set_migration_campaign_state(
              Catalog, Id, Status, ?TIMEOUT), State};
handle_call({status, Id}, _From, State = #{catalog := Catalog}) ->
    {reply, erlite_catalog:migration_campaign(
              Catalog, Id, ?TIMEOUT, consistent), State};
handle_call(_, _From, State) -> {reply, {error, not_configured}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.

validate_set(Set, Migrations, Options)
  when is_binary(Set), byte_size(Set) > 0, is_list(Migrations),
       Migrations =/= [], is_map(Options) ->
    Databases = maps:get(databases, Options, []),
    Canary = maps:get(canary_size, Options, 1),
    Batch = maps:get(batch_size, Options, 10),
    Retries = maps:get(max_retries, Options, 3),
    Key = maps:get(idempotency_key, Options, undefined),
    case valid_chain(Migrations) andalso is_list(Databases) andalso
         Databases =/= [] andalso is_integer(Canary) andalso Canary > 0 andalso
         is_integer(Batch) andalso Batch > 0 andalso
         is_integer(Retries) andalso Retries >= 0 andalso
         is_binary(Key) andalso byte_size(Key) > 0 of
        true -> {ok, #{migrations => Migrations,
                       databases => lists:usort(Databases),
                       canary_size => Canary, batch_size => Batch,
                       max_retries => Retries, idempotency_key => Key}};
        false -> {error, invalid_migration_set}
    end;
validate_set(_, _, _) -> {error, invalid_migration_set}.

campaign_id(Set, Key) ->
    <<Id:16/binary, _/binary>> =
        crypto:hash(sha256, term_to_binary({fleet_migration, Set, Key},
                                           [deterministic])),
    Id.

valid_chain([#{id := Id, from := From, to := To, statements := Statements} | Rest])
  when is_binary(Id), is_integer(From), is_integer(To), To =:= From + 1,
       is_list(Statements), Statements =/= [] ->
    case erlite_raft_command:new_migration(<<"validation">>, Id, From, To,
                                           Statements) of
        {ok, _} -> valid_next(To, Rest);
        _ -> false
    end;
valid_chain(_) -> false.
valid_next(_, []) -> true;
valid_next(Previous, [#{from := Previous} | _] = Rest) -> valid_chain(Rest);
valid_next(_, _) -> false.

run_batch(Id, Catalog) ->
    case erlite_catalog:migration_campaign(Catalog, Id, ?TIMEOUT, consistent) of
        {ok, #{status := paused}} -> {error, campaign_paused};
        {ok, #{status := Status}} when Status =:= complete; Status =:= failed ->
            {ok, Status};
        {ok, Campaign} -> execute_selected(Campaign, Catalog);
        Error -> Error
    end.

execute_selected(Campaign, Catalog) ->
    Entries = maps:get(entries, Campaign),
    Ordered = lists:sort(maps:keys(Entries)),
    CanarySize = min(maps:get(canary_size, Campaign), length(Ordered)),
    {Canaries, Rest} = lists:split(CanarySize, Ordered),
    CanaryDone = lists:all(fun(Db) -> maps:get(status, maps:get(Db, Entries))
                                      =:= complete end, Canaries),
    Candidates = case CanaryDone of true -> Rest; false -> Canaries end,
    Eligible = [Db || Db <- Candidates, eligible(maps:get(Db, Entries),
                                                  maps:get(max_retries, Campaign))],
    Limit = case CanaryDone of true -> maps:get(batch_size, Campaign);
                                false -> CanarySize end,
    Selected = lists:sublist(Eligible, Limit),
    Results = [execute_database(Db, Campaign, Catalog) || Db <- Selected],
    case {CanaryDone, lists:any(fun({_, {error, _}}) -> true;
                                  ({_, _}) -> false end,
                                Results)} of
        {false, true} ->
            _ = erlite_catalog:set_migration_campaign_state(
                  Catalog, maps:get(campaign_id, Campaign), paused, ?TIMEOUT),
            {error, {canary_failed, Results}};
        _ -> {ok, Results}
    end.

eligible(#{status := complete}, _) -> false;
eligible(#{attempts := Attempts}, Max) -> Attempts =< Max.

execute_database(DatabaseId, Campaign, Catalog) ->
    Result = migrate_chain(DatabaseId, maps:get(campaign_id, Campaign),
                           maps:get(migration_set, Campaign),
                           maps:get(migrations, Campaign), Catalog),
    Recorded = case Result of ok -> ok; {error, Reason} -> {error, Reason} end,
    _ = erlite_catalog:record_migration_result(
          Catalog, maps:get(campaign_id, Campaign), DatabaseId, Recorded,
          ?TIMEOUT),
    {DatabaseId, Result}.

migrate_chain(_DatabaseId, _CampaignId, _Set, [], _Catalog) -> ok;
migrate_chain(DatabaseId, CampaignId, Set,
              [#{id := Id, from := From, to := To,
                 statements := Statements} | Rest], Catalog) ->
    case erlite_catalog:database(Catalog, DatabaseId, ?TIMEOUT, consistent) of
        {ok, #{state := Lifecycle}} when Lifecycle =/= ready ->
            {error, {database_not_ready, Lifecycle}};
        {ok, #{movement := #{operation_id := OperationId}}} ->
            {error, {movement_in_progress, OperationId}};
        {ok, #{repair := #{operation_id := OperationId}}} ->
            {error, {repair_in_progress, OperationId}};
        {ok, #{state := ready, generation := _Generation,
               schema_version := Current}} when Current =:= To ->
            migrate_chain(DatabaseId, CampaignId, Set, Rest, Catalog);
        {ok, #{state := ready, generation := Generation,
               schema_version := From}} ->
            case erlite_catalog:prepare_database_migration(
                   Catalog, DatabaseId, CampaignId, Id, Generation, From, To,
                   ?TIMEOUT) of
                ok -> apply_fenced_migration(
                        DatabaseId, CampaignId, Set, Id, Generation, From, To,
                        Statements, Rest, Catalog);
                Error -> Error
            end;
        {ok, #{schema_version := Current}} ->
            {error, {unexpected_schema_version, From, Current}};
        Error -> Error
    end.

apply_fenced_migration(DatabaseId, CampaignId, Set, Id, Generation, From, To,
                       Statements, Rest, Catalog) ->
    {ok, Command} = erlite_raft_command:new_migration(
                      Set, Id, From, To, Statements),
    case erlite_databases:migrate(DatabaseId, Command, ?TIMEOUT) of
        {ok, _} ->
            case erlite_catalog:finish_database_migration(
                   Catalog, DatabaseId, CampaignId, Id, Generation, From, To,
                   ?TIMEOUT) of
                ok -> migrate_chain(DatabaseId, CampaignId, Set, Rest, Catalog);
                Error -> Error
            end;
        Error ->
            _ = erlite_catalog:abort_database_migration(
                  Catalog, DatabaseId, CampaignId, Id, Generation, ?TIMEOUT),
            Error
    end.
