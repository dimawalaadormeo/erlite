-module(erlite_sqlite_adapter).

-export_type([connection/0,
              error_reason/0,
              execute_result/0,
              open_options/0,
              params/0,
              query_result/0,
              sqlite_value/0,
              statement/0,
              statement_result/0]).

-type connection() :: term().
-type error_reason() :: term().
-type sqlite_value() :: null | integer() | float() | binary().
-type params() :: [sqlite_value()].
-type open_options() :: map().
-type execute_result() :: #{changes := non_neg_integer(),
                            last_insert_rowid := integer() | undefined}.
-type query_result() :: #{columns := [binary()], rows := [[sqlite_value()]]}.
-type statement() :: {execute, binary(), params()} | {query, binary(), params()}.
-type statement_result() :: execute_result() | query_result().

-callback open(file:filename_all(), open_options()) ->
    {ok, connection()} | {error, error_reason()}.
-callback close(connection()) -> ok | {error, error_reason()}.
-callback execute(connection(), binary(), params()) ->
    {ok, execute_result()} | {error, error_reason()}.
-callback query(connection(), binary(), params()) ->
    {ok, query_result()} | {error, error_reason()}.
-callback transaction(connection(), [statement()]) ->
    {ok, [statement_result()]} | {error, error_reason()}.

