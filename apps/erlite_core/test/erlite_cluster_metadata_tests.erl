-module(erlite_cluster_metadata_tests).

-include_lib("eunit/include/eunit.hrl").

metadata_lifecycle_is_durable_and_idempotent_test() ->
    Root = root(),
    Id = <<7:128>>,
    try
        {ok, Initial} = erlite_cluster_metadata:ensure(Root, Id, <<"test">>),
        initializing = maps:get(state, Initial),
        {ok, Active} = erlite_cluster_metadata:activate(
                         Root, {erlite_catalog, node()}),
        active = maps:get(state, Active),
        ?assertEqual({ok, Active}, erlite_cluster_metadata:load(Root)),
        ?assertEqual({ok, Active},
                     erlite_cluster_metadata:ensure(Root, Id, <<"test">>)),
        {ok, Left} = erlite_cluster_metadata:mark_left(Root),
        left = maps:get(state, Left)
    after cleanup(Root) end.

cluster_identity_conflict_is_rejected_test() ->
    Root = root(),
    try
        {ok, _} = erlite_cluster_metadata:ensure(Root, <<1:128>>, <<"one">>),
        ?assertEqual({error, cluster_identity_mismatch},
                     erlite_cluster_metadata:ensure(
                       Root, <<2:128>>, <<"two">>))
    after cleanup(Root) end.

root() -> filename:join("/tmp", "erlite-cluster-metadata-" ++
                         integer_to_list(erlang:unique_integer([positive]))).

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
