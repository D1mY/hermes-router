-module(hermes_galileosky).

-behaviour(application).

-export([start/0, start/2, stop/0, stop/1]).

start() ->
    hermes_galileosky_sup:start_link(),
    ok.

start(_Type, _StartArgs) ->
    hermes_galileosky_sup:start_link().

stop() -> ok.

stop(_State) ->
    ok.