-module(erlite_core_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case erlite_core_sup:start_link() of
        {ok, Pid} ->
            _ = spawn(erlite_release_report, run, []),
            {ok, Pid};
        Other -> Other
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

