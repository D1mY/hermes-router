%%%-------------------------------------------------------------------
%% @doc hermes_galileosky top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hermes_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 3, 10},
          [{hermes_worker,
            {hermes_worker, start_link, []},
            permanent,
            10000,
            worker,
            [hermes_worker]}
          ]}}.
