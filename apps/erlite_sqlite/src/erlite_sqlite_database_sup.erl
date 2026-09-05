-module(erlite_sqlite_database_sup).
-behaviour(supervisor).

-export([start_link/0, start_owner/2, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_owner(file:filename_all(), binary()) -> supervisor:startchild_ret().
start_owner(StorageRoot, DatabaseId) ->
    Child = #{id => make_ref(),
              start => {erlite_sqlite_owner, start_link, [StorageRoot, DatabaseId]},
              restart => temporary,
              shutdown => 5000,
              type => worker},
    supervisor:start_child(?MODULE, Child).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 3,
                 period => 5},
    {ok, {SupFlags, []}}.

