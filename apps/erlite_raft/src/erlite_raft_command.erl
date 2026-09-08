-module(erlite_raft_command).

-export([new_transaction/3, new_migration/5, validate/1, type/1,
         transaction_id/1, migration_id/1, migration_set/1,
         schema_version/1, target_schema_version/1, statements/1, hash/1]).
-export_type([command/0, mutation/0]).

-type mutation() :: {binary(), erlite_sqlite_adapter:params()}.
-opaque command() :: {transaction, binary(), non_neg_integer(), [mutation()]} |
                     {migration, binary(), binary(), non_neg_integer(),
                      pos_integer(), [mutation()]}.

-spec new_transaction(binary(), non_neg_integer(), [mutation()]) ->
    {ok, command()} | {error, term()}.
new_transaction(TransactionId, SchemaVersion, Mutations) ->
    Command = {transaction, TransactionId, SchemaVersion, Mutations},
    case validate(Command) of
        ok -> {ok, Command};
        {error, _Reason} = Error -> Error
    end.

-spec new_migration(binary(), binary(), non_neg_integer(), pos_integer(),
                    [mutation()]) -> {ok, command()} | {error, term()}.
new_migration(Set, MigrationId, FromVersion, ToVersion, Statements) ->
    Command = {migration, Set, MigrationId, FromVersion, ToVersion, Statements},
    case validate(Command) of
        ok -> {ok, Command};
        {error, _Reason} = Error -> Error
    end.

-spec validate(term()) -> ok | {error, term()}.
validate({transaction, TransactionId, SchemaVersion, Mutations}) ->
    case validate_transaction_id(TransactionId) of
        ok ->
            case validate_schema_version(SchemaVersion) of
                ok -> validate_mutations(Mutations);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end;
validate({migration, Set, MigrationId, FromVersion, ToVersion, Statements}) ->
    case valid_name(Set) andalso valid_name(MigrationId) andalso
         is_integer(FromVersion) andalso FromVersion >= 0 andalso
         is_integer(ToVersion) andalso ToVersion =:= FromVersion + 1 andalso
         is_list(Statements) andalso Statements =/= [] of
        true -> validate_migration_statements(Statements);
        false -> {error, invalid_migration}
    end;
validate(Command) ->
    {error, {invalid_command, Command}}.

type({transaction, _, _, _}) -> transaction;
type({migration, _, _, _, _, _}) -> migration.

-spec transaction_id(command()) -> binary().
transaction_id({transaction, TransactionId, _SchemaVersion, _Mutations}) ->
    TransactionId;
transaction_id({migration, Set, MigrationId, From, To, _}) ->
    crypto:hash(sha256, term_to_binary({migration, Set, MigrationId, From, To},
                                      [deterministic])).

migration_id({migration, _Set, MigrationId, _, _, _}) -> MigrationId.
migration_set({migration, Set, _MigrationId, _, _, _}) -> Set.

-spec schema_version(command()) -> non_neg_integer().
schema_version({transaction, _TransactionId, SchemaVersion, _Mutations}) ->
    SchemaVersion;
schema_version({migration, _, _, FromVersion, _, _}) -> FromVersion.

target_schema_version({migration, _, _, _, ToVersion, _}) -> ToVersion;
target_schema_version({transaction, _, Version, _}) -> Version.

-spec statements(command()) -> [erlite_sqlite_adapter:statement()].
statements({transaction, _TransactionId, _SchemaVersion, Mutations}) ->
    [{execute, Sql, Params} || {Sql, Params} <- Mutations];
statements({migration, _, _, _, _, Mutations}) ->
    [{execute, Sql, Params} || {Sql, Params} <- Mutations].

-spec hash(command()) -> binary().
hash(Command) ->
    crypto:hash(sha256, term_to_binary(Command, [deterministic])).

validate_transaction_id(TransactionId)
  when is_binary(TransactionId), byte_size(TransactionId) > 0 ->
    ok;
validate_transaction_id(TransactionId) ->
    {error, {invalid_transaction_id, TransactionId}}.

validate_schema_version(SchemaVersion)
  when is_integer(SchemaVersion), SchemaVersion >= 0 ->
    ok;
validate_schema_version(SchemaVersion) ->
    {error, {invalid_schema_version, SchemaVersion}}.

validate_mutations([]) ->
    {error, empty_transaction};
validate_mutations(Mutations) when is_list(Mutations) ->
    validate_mutation_list(Mutations);
validate_mutations(Mutations) ->
    {error, {invalid_mutations, Mutations}}.

validate_mutation_list([]) ->
    ok;
validate_mutation_list([{Sql, Params} | Rest])
  when is_binary(Sql), byte_size(Sql) > 0, is_list(Params) ->
    case validate_params(Params) of
        ok ->
            case erlite_raft_sql_policy:validate(Sql, Params) of
                ok -> validate_mutation_list(Rest);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end;
validate_mutation_list([Mutation | _Rest]) ->
    {error, {invalid_mutation, Mutation}}.

validate_migration_statements([]) -> ok;
validate_migration_statements([{Sql, Params} | Rest])
  when is_binary(Sql), byte_size(Sql) > 0, is_list(Params) ->
    case validate_params(Params) of
        ok ->
            case erlite_raft_migration_policy:validate(Sql, Params) of
                ok -> validate_migration_statements(Rest);
                Error -> Error
            end;
        Error -> Error
    end;
validate_migration_statements([Statement | _]) ->
    {error, {invalid_migration_statement, Statement}}.

valid_name(Value) -> is_binary(Value) andalso byte_size(Value) > 0 andalso
                     byte_size(Value) =< 255.

validate_params([]) ->
    ok;
validate_params([Value | Rest])
  when Value =:= null; is_integer(Value); is_float(Value); is_binary(Value) ->
    validate_params(Rest);
validate_params([Value | _Rest]) ->
    {error, {invalid_parameter, Value}}.
