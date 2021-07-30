-module(hermes_json).

-behaviour(application).

-export([start/2, stop/1]).

-rabbit_boot_step({?MODULE,
                   [{description, "Hermes to JSON"},
                    {mfa,         {hermes_json,
                                   start,
                                   [normal, []]}},
                    {requires,    direct_client}]}).

start(normal, []) ->
    erlang:spawn(hermes_json_sup,start_link,[]),
    ok.

stop(_State) ->
    ok.