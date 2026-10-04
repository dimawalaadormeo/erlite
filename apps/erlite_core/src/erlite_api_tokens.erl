-module(erlite_api_tokens).

-export([issue_admin/1, rotate_admin/2, revoke_admin/1,
         issue_service/1, rotate_service/2, revoke_service/1,
         revoke_database/1, enable/0, list/0, audit/0, identity/1]).

-define(TIMEOUT, 5000).
-define(TOKEN_BYTES, 32).
-define(TOKEN_STORE_PROTOCOL, 2).

-spec issue_admin(binary()) -> {ok, binary()} | {error, term()}.
issue_admin(Name) -> issue({admin, Name}).

-spec issue_service(binary()) -> {ok, binary()} | {error, term()}.
issue_service(DatabaseId) -> issue({service, DatabaseId}).

%% GraceMs keeps the previous token valid for that many milliseconds; 0 revokes
%% it at once.
-spec rotate_admin(binary(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
rotate_admin(Name, GraceMs) -> rotate({admin, Name}, GraceMs).

-spec rotate_service(binary(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
rotate_service(DatabaseId, GraceMs) -> rotate({service, DatabaseId}, GraceMs).

-spec revoke_admin(binary()) -> ok | {error, term()}.
revoke_admin(Name) -> revoke({admin, Name}).

-spec revoke_service(binary()) -> ok | {error, term()}.
revoke_service(DatabaseId) -> revoke({service, DatabaseId}).

-spec revoke_database(binary()) -> ok | {error, term()}.
revoke_database(DatabaseId) ->
    case revoke_service(DatabaseId) of
        {error, token_store_disabled} -> ok;
        Result -> Result
    end.

%% Turns the token store on. Refused unless every active catalog node runs a
%% release that supports it, so no older node can miss a token command.
-spec enable() -> ok | {error, term()}.
enable() ->
    case catalog() of
        {ok, Catalog} ->
            case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
                {ok, #{nodes := Nodes}} ->
                    case check_live_releases([Node || #{state := active} = Node <- Nodes]) of
                        ok -> erlite_catalog:enable_token_store(Catalog, ?TIMEOUT);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

%% Asks each node what it is actually running, rather than trusting the stored
%% record, so a node that was upgraded in place is judged by its current release.
check_live_releases(Nodes) ->
    Old = [maps:get(node_name, Node) || Node <- Nodes,
           live_protocol(Node) < ?TOKEN_STORE_PROTOCOL],
    case Old of
        [] -> ok;
        _ -> {error, {nodes_below_token_store_protocol, Old}}
    end.

live_protocol(#{server_id := {_, ErlangNode}}) ->
    case rpc:call(ErlangNode, erlite_release, metadata, [], ?TIMEOUT) of
        #{cluster_protocol := Protocol} -> Protocol;
        _ -> 0
    end.

-spec audit() -> [map()] | {error, term()}.
audit() ->
    case catalog() of
        {ok, Catalog} ->
            case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
                {ok, #{audit := Entries}} -> Entries;
                Error -> Error
            end;
        Error -> Error
    end.

-spec list() -> [map()] | {error, term()}.
list() ->
    case catalog() of
        {ok, Catalog} ->
            case erlite_catalog:status(Catalog, ?TIMEOUT, consistent) of
                {ok, #{tokens := Tokens}} -> Tokens;
                Error -> Error
            end;
        Error -> Error
    end.

-spec identity(binary()) -> {ok, map()} | {error, term()}.
identity(Token) when is_binary(Token) ->
    Hash = digest(Token),
    Now = erlang:system_time(millisecond),
    case local_identity(Hash, Now) of
        {ok, _} = Found -> Found;
        %% Only a positive local hit is trusted. A local miss may mean the token
        %% was issued elsewhere and is not applied here yet, so it is confirmed
        %% by the consistent read, which is also the authority for refusals.
        _ ->
            case catalog() of
                {ok, Catalog} ->
                    identity_result(erlite_catalog:token_identity(
                                      Catalog, Hash, Now, ?TIMEOUT));
                _ -> {error, token_store_unavailable}
            end
    end.

%% A catalog member answers from its own replica. A node that is not a member
%% has no local replica, and the caller falls back to the consistent read.
local_identity(Hash, Now) ->
    identity_result(erlite_catalog:token_identity_local(
                      erlite_cluster:catalog_server_id(), Hash, Now, ?TIMEOUT)).

identity_result({ok, {admin, _}}) -> {ok, #{role => admin}};
identity_result({ok, {service, DatabaseId}}) ->
    {ok, #{role => service, databases => [DatabaseId]}};
identity_result({error, invalid_bearer_token}) -> {error, invalid_bearer_token};
identity_result(_) -> {error, token_store_unavailable}.

issue(Key) ->
    Token = new_token(),
    case catalog() of
        {ok, Catalog} ->
            case erlite_catalog:issue_token(Catalog, Key, digest(Token),
                                            ?TIMEOUT) of
                ok -> {ok, Token};
                Error -> Error
            end;
        Error -> Error
    end.

rotate(Key, GraceMs) when is_integer(GraceMs), GraceMs >= 0 ->
    Token = new_token(),
    ExpiresAt = case GraceMs of
                    0 -> 0;
                    _ -> erlang:system_time(millisecond) + GraceMs
                end,
    case catalog() of
        {ok, Catalog} ->
            case erlite_catalog:rotate_token(Catalog, Key, digest(Token),
                                             ExpiresAt, ?TIMEOUT) of
                ok -> {ok, Token};
                Error -> Error
            end;
        Error -> Error
    end;
rotate(_Key, _GraceMs) ->
    {error, invalid_grace_period}.

revoke(Key) ->
    case catalog() of
        {ok, Catalog} -> erlite_catalog:revoke_token(Catalog, Key, ?TIMEOUT);
        Error -> Error
    end.

catalog() ->
    case application:get_env(erlite_core, catalog_server) of
        {ok, Catalog} -> {ok, Catalog};
        undefined -> {error, catalog_not_configured}
    end.

new_token() ->
    binary:encode_hex(crypto:strong_rand_bytes(?TOKEN_BYTES), lowercase).

digest(Token) -> crypto:hash(sha256, Token).
