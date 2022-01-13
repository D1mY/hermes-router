-module(hermes_galileosky_filer).

-behaviour(application).

-export([start/2, stop/1]).

-rabbit_boot_step({?MODULE,
                   [{description, "Hermes Galileosky filer"},
                    {mfa,         {hermes_galileosky_filer,
                                   start,
                                   [normal, []]}},
                    {requires,    direct_client}]}).

start(normal, []) ->
    erlang:spawn(hermes_galileosky_filer_sup,start_link,[]),
    ok.

stop(_State) ->
    ok.