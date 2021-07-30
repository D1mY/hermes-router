%%%-------------------------------------------------------------------
%% @doc hermes_galileosky_broker top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hermes_galileosky_broker_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 3, 10},
          [{galileoskydec,
            {galileoskydec, start_link, []},
            permanent,
            10000,
            worker,
            [galileoskydec]}
          ]}}.
