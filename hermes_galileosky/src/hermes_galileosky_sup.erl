%%%-------------------------------------------------------------------
%% @doc hermes_galileosky top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hermes_galileosky_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => rest_for_one,
            intensity => 3,
            period => 10},
            [#{id => hermes_worker,
                start => {hermes_worker, start_link, []},
                restart => permanent,
                shutdown => 10000,
                type => worker,
                modules =>[hermes_worker]},
            #{id => hermes_accept_sup,
                start => {hermes_accept_sup, start_link, []},
                restart => permanent,
                shutdown => 10000,
                type => supervisor,
                modules => [hermes_accept_sup]},
            #{id => galileo_pacman_sup,
                start => {galileo_pacman_sup, start_link, []},
                restart => permanent,
                shutdown => 10000,
                type => supervisor,
                modules => [galileo_pacman_sup]}
            ]}}.
