-module(hermes_galileosky).

-behaviour(application).

-export([start/2, stop/1]).

-rabbit_boot_step({?MODULE,
                   [{description, "Hermes for Galileosky"},
                    {mfa,         {hermes_galileosky,
                                   start,
                                   [normal, []]}},
                    {requires,    direct_client}]}).

start(normal, []) ->
    erlang:spawn(hermes_galileosky_sup,start_link,[]),
    ok.

stop(_State) ->
    ok.