-module(erlite_sqlite_compatibility).

-export([runtime_identity/1, fingerprint/1, validate/1, verify/2]).
-export_type([runtime_identity/0]).

-type runtime_identity() ::
    #{sqlite_version := binary(),
      sqlite_source_id := binary(),
      compile_options := [binary()]}.

-spec runtime_identity(erlite_sqlite:connection()) ->
    {ok, runtime_identity()} | {error, term()}.
runtime_identity(Connection) ->
    case read_version(Connection) of
        {ok, Version, SourceId} ->
            case read_compile_options(Connection) of
                {ok, Options} ->
                    {ok, #{sqlite_version => Version,
                           sqlite_source_id => SourceId,
                           compile_options => lists:sort(Options)}};
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-spec fingerprint(runtime_identity()) -> binary().
fingerprint(#{sqlite_version := Version,
              sqlite_source_id := SourceId,
              compile_options := Options}) ->
    Canonical = {sqlite_runtime, Version, SourceId, lists:sort(Options)},
    binary:encode_hex(
      crypto:hash(sha256, term_to_binary(Canonical, [deterministic])), lowercase).

-spec verify(erlite_sqlite:connection(), runtime_identity()) ->
    ok | {error, term()}.
verify(Connection, Expected) ->
    case validate(Expected) of
        ok -> verify_valid_identity(Connection, Expected);
        {error, _Reason} = Error -> Error
    end.

verify_valid_identity(Connection, Expected) ->
    case runtime_identity(Connection) of
        {ok, Expected} -> ok;
        {ok, Actual} ->
            {error, {incompatible_sqlite_runtime,
                     fingerprint(Expected), fingerprint(Actual)}};
        {error, _Reason} = Error -> Error
    end.

-spec validate(term()) -> ok | {error, term()}.
validate(#{sqlite_version := Version,
           sqlite_source_id := SourceId,
           compile_options := Options} = Identity)
  when is_binary(Version), is_binary(SourceId), is_list(Options) ->
    case lists:all(fun is_binary/1, Options) of
        true -> ok;
        false -> {error, {invalid_sqlite_runtime_identity, Identity}}
    end;
validate(Identity) ->
    {error, {invalid_sqlite_runtime_identity, Identity}}.

read_version(Connection) ->
    Sql = <<"SELECT sqlite_version() AS sqlite_version, "
            "sqlite_source_id() AS sqlite_source_id">>,
    case erlite_sqlite:query(Connection, Sql, []) of
        {ok, #{rows := [[Version, SourceId]]}}
          when is_binary(Version), is_binary(SourceId) ->
            {ok, Version, SourceId};
        {ok, #{rows := Rows}} ->
            {error, {invalid_sqlite_runtime_identity, Rows}};
        {error, _Reason} = Error -> Error
    end.

read_compile_options(Connection) ->
    case erlite_sqlite:query(Connection, <<"PRAGMA compile_options">>, []) of
        {ok, #{rows := Rows}} -> collect_compile_options(Rows, []);
        {error, _Reason} = Error -> Error
    end.

collect_compile_options([], Options) ->
    {ok, Options};
collect_compile_options([[Option] | Rest], Options) when is_binary(Option) ->
    collect_compile_options(Rest, [Option | Options]);
collect_compile_options(Rows, _Options) ->
    {error, {invalid_sqlite_compile_options, Rows}}.
