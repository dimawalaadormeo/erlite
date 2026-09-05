-module(erlite_sqlite_compatibility_tests).

-include_lib("eunit/include/eunit.hrl").

runtime_identity_is_complete_and_canonical_test() ->
    with_database(
      fun(Connection) ->
              {ok, Identity} = erlite_sqlite_compatibility:runtime_identity(Connection),
              #{sqlite_version := Version,
                sqlite_source_id := SourceId,
                compile_options := Options} = Identity,
              ?assert(byte_size(Version) > 0),
              ?assert(byte_size(SourceId) > 0),
              ?assertNotEqual([], Options),
              ?assertEqual(lists:sort(Options), Options),
              Fingerprint = erlite_sqlite_compatibility:fingerprint(Identity),
              ?assertMatch(<<_:64/binary>>, Fingerprint),
              ?assertEqual(Fingerprint,
                           erlite_sqlite_compatibility:fingerprint(Identity)),
              ?assertEqual(ok,
                           erlite_sqlite_compatibility:verify(Connection, Identity))
      end).

runtime_mismatch_is_rejected_without_exposing_build_details_test() ->
    with_database(
      fun(Connection) ->
              {ok, Actual} = erlite_sqlite_compatibility:runtime_identity(Connection),
              Expected = Actual#{sqlite_version => <<"different">>},
              ExpectedFingerprint =
                  erlite_sqlite_compatibility:fingerprint(Expected),
              ActualFingerprint = erlite_sqlite_compatibility:fingerprint(Actual),
              ?assertEqual(
                 {error, {incompatible_sqlite_runtime,
                          ExpectedFingerprint, ActualFingerprint}},
                 erlite_sqlite_compatibility:verify(Connection, Expected))
      end).

with_database(Test) ->
    Path = temporary_database_path(),
    {ok, Connection} = erlite_sqlite:open(Path),
    try
        Test(Connection)
    after
        ok = erlite_sqlite:close(Connection),
        ok = delete_if_present(Path)
    end.

temporary_database_path() ->
    Name = io_lib:format("erlite-compatibility-~B.sqlite",
                         [erlang:unique_integer([positive, monotonic])]),
    filename:join(temp_directory(), lists:flatten(Name)).

temp_directory() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> Directory
    end.

delete_if_present(Path) ->
    case file:delete(Path) of
        ok -> ok;
        {error, enoent} -> ok
    end.
