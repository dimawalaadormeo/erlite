-module(erlite_raft_command).

-export([new_transaction/3, validate/1, transaction_id/1,
         schema_version/1, statements/1]).
-export_type([command/0, mutation/0]).

-type mutation() :: {binary(), erlite_sqlite_adapter:params()}.
-opaque command() :: {transaction, binary(), non_neg_integer(), [mutation()]}.

-spec new_transaction(binary(), non_neg_integer(), [mutation()]) ->
    {ok, command()} | {error, term()}.
new_transaction(TransactionId, SchemaVersion, Mutations) ->
    Command = {transaction, TransactionId, SchemaVersion, Mutations},
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
validate(Command) ->
    {error, {invalid_command, Command}}.

-spec transaction_id(command()) -> binary().
transaction_id({transaction, TransactionId, _SchemaVersion, _Mutations}) ->
    TransactionId.

-spec schema_version(command()) -> non_neg_integer().
schema_version({transaction, _TransactionId, SchemaVersion, _Mutations}) ->
    SchemaVersion.

-spec statements(command()) -> [erlite_sqlite_adapter:statement()].
statements({transaction, _TransactionId, _SchemaVersion, Mutations}) ->
    [{execute, Sql, Params} || {Sql, Params} <- Mutations].

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

validate_params([]) ->
    ok;
validate_params([Value | Rest])
  when Value =:= null; is_integer(Value); is_float(Value); is_binary(Value) ->
    validate_params(Rest);
validate_params([Value | _Rest]) ->
    {error, {invalid_parameter, Value}}.
