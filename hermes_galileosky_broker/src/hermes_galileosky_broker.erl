-module(hermes_galileosky_broker).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _StartArgs) ->
    hermes_galileosky_broker_sup:start_link().

stop(_State) ->
    ok.