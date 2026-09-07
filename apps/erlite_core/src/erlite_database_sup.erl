-module(erlite_database_sup).
-behaviour(supervisor).

-export([start_link/0, start_database/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_database(DatabaseId, Options) ->
    Child = #{id => DatabaseId,
              start => {erlite_database, start_link, [DatabaseId, Options]},
              restart => temporary,
              shutdown => 30000,
              type => worker},
    supervisor:start_child(?MODULE, Child).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
