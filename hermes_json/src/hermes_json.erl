-module(hermes_json).

-behaviour(application).

-export([start/0, start/2, stop/0, stop/1]).

start() ->
    hermes_json_sup:start_link().
start(_Type, _StartArgs) ->
    hermes_json_sup:start_link().

stop() ->
    ok.
stop(_State) ->
    ok.
