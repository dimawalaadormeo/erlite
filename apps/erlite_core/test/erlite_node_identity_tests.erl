-module(erlite_node_identity_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

identity_is_stable_across_load_and_ensure_test() ->
    Root = temporary_root(),
    try
        {ok, Identity} = erlite_node_identity:ensure(Root, <<"erlite@node-a">>),
        ?assertEqual({ok, Identity}, erlite_node_identity:load(Root)),
        ?assertEqual({ok, Identity},
                     erlite_node_identity:ensure(Root, <<"erlite@node-a">>)),
        Path = filename:join([Root, "node", "identity"]),
        {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
        ?assertEqual(0, Mode band 8#077)
    after
        cleanup(Root)
    end.

conflicting_node_name_is_rejected_test() ->
    Root = temporary_root(),
    try
        {ok, _} = erlite_node_identity:ensure(Root, <<"erlite@node-a">>),
        ?assertEqual(
           {error, {node_name_mismatch, <<"erlite@node-a">>, <<"erlite@node-b">>}},
           erlite_node_identity:ensure(Root, <<"erlite@node-b">>))
    after
        cleanup(Root)
    end.

corrupt_identity_is_not_replaced_test() ->
    Root = temporary_root(),
    Path = filename:join([Root, "node", "identity"]),
    try
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, <<"not an Erlang term">>),
        ?assertEqual({error, invalid_node_identity},
                     erlite_node_identity:ensure(Root, <<"erlite@node-a">>)),
        ?assertEqual({ok, <<"not an Erlang term">>}, file:read_file(Path))
    after
        cleanup(Root)
    end.

invalid_inputs_are_rejected_test() ->
    ?assertEqual({error, storage_root_must_be_absolute},
                 erlite_node_identity:ensure("relative", <<"erlite@node-a">>)),
    ?assertEqual({error, invalid_node_name},
                 erlite_node_identity:ensure("/tmp", <<>>)).

temporary_root() ->
    filename:join("/tmp", "erlite-node-identity-" ++
                  integer_to_list(erlang:unique_integer([positive]))).

cleanup(Path) ->
    case file:list_dir(Path) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> cleanup(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {error, enotdir} -> file:delete(Path);
        {error, enoent} -> ok
    end.
