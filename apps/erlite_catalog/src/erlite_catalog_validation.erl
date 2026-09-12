-module(erlite_catalog_validation).

-export([valid_node/1, valid_database_id/1]).

-spec valid_node(term()) -> boolean().
valid_node(#{node_id := NodeId, node_name := NodeName,
             server_id := {ServerName, ErlangNode}}) ->
    is_binary(NodeId) andalso byte_size(NodeId) =:= 16 andalso
        is_binary(NodeName) andalso byte_size(NodeName) > 0 andalso
        is_atom(ServerName) andalso is_atom(ErlangNode);
valid_node(_) -> false.

-spec valid_database_id(term()) -> boolean().
valid_database_id(DatabaseId) ->
    is_binary(DatabaseId) andalso byte_size(DatabaseId) > 0 andalso
        byte_size(DatabaseId) =< 1024.
