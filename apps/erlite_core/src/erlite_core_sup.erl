-module(erlite_core_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 5},
    Children = [#{id => erlite_database_sup,
                  start => {erlite_database_sup, start_link, []},
                  type => supervisor},
                #{id => erlite_databases,
                  start => {erlite_databases, start_link, []},
                  type => worker}],
    {ok, {SupFlags, Children}}.
