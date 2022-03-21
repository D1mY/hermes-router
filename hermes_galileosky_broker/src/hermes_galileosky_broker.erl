-module(hermes_galileosky_broker).

-behaviour(application).

-export([start/2, stop/1]).

-rabbit_boot_step({?MODULE,
                   [{description, "Hermes Galileosky broker"},
                    {mfa,         {hermes_galileosky_broker,
                                   start,
                                   [normal, []]}},
                    {requires,    direct_client}]}).

% start(normal, []) ->
%     erlang:spawn(hermes_galileosky_broker_sup,start_link,[]),
%     ok.
start(normal, []) ->
    hermes_galileosky_broker_sup:start_link(),
    ok.

stop(_State) ->
    ok.