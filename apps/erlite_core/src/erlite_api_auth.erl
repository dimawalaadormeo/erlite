-module(erlite_api_auth).

-export([authenticate/2, authorize/3, valid_credentials/1]).

valid_credentials(Credentials) when is_list(Credentials), Credentials =/= [] ->
    Tokens = [maps:get(token, Credential, undefined)
              || Credential <- Credentials],
    lists:all(fun valid_credential/1, Credentials) andalso
        length(Tokens) =:= length(lists:usort(Tokens));
valid_credentials(_) -> false.

authenticate(undefined, _Credentials) -> {error, missing_bearer_token};
authenticate(Token, Credentials) when is_binary(Token), is_list(Credentials) ->
    case valid_credentials(Credentials) of
        true -> authenticate_list(Token, Credentials);
        false -> {error, invalid_credentials_config}
    end;
authenticate(_Token, _Credentials) -> {error, invalid_credentials_config}.

authenticate_list(_Token, []) -> {error, invalid_bearer_token};
authenticate_list(Token, [Credential | Rest]) ->
    case valid_credential(Credential) andalso
         secure_equal(Token, maps:get(token, Credential, <<>>)) of
        true -> {ok, maps:remove(token, Credential)};
        false -> authenticate_list(Token, Rest)
    end.

authorize(#{role := admin}, _Action, _DatabaseId) -> ok;
authorize(#{role := service, databases := all}, data, _DatabaseId) -> ok;
authorize(#{role := service, databases := Databases}, data, DatabaseId)
  when is_list(Databases) ->
    case lists:member(DatabaseId, Databases) of
        true -> ok;
        false -> {error, database_forbidden}
    end;
authorize(_Identity, control, _DatabaseId) -> {error, admin_required};
authorize(_Identity, _Action, _DatabaseId) -> {error, database_forbidden}.

valid_credential(#{token := Token, role := admin}) ->
    is_binary(Token) andalso byte_size(Token) >= 32;
valid_credential(#{token := Token, role := service, databases := Databases}) ->
    is_binary(Token) andalso byte_size(Token) >= 32 andalso
        (Databases =:= all orelse
         (is_list(Databases) andalso lists:all(fun is_binary/1, Databases)));
valid_credential(_) -> false.

secure_equal(Left, Right) ->
    crypto:hash_equals(crypto:hash(sha256, Left), crypto:hash(sha256, Right)).
