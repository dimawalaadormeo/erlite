-module(erlite_sqlite_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 3,
                 period => 5},
    Children = [
        #{id => erlite_sqlite_database_sup,
          start => {erlite_sqlite_database_sup, start_link, []},
          type => supervisor},
        #{id => erlite_sqlite_databases,
          start => {erlite_sqlite_databases, start_link, []}}
    ],
    {ok, {SupFlags, Children}}.

