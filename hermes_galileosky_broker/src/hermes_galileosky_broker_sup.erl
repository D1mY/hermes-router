%%%-------------------------------------------------------------------
%% @doc hermes_galileosky_broker top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hermes_galileosky_broker_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

% init([]) ->
%     {ok, {{one_for_one, 3, 10},
%           [{galileoskydec,
%             {galileoskydec, start_link, []},
%             permanent,
%             10000,
%             worker,
%             [galileoskydec]}
%           ]}}.

init([]) ->
    {ok, {#{strategy => one_for_all,
            intensity => 3,
            period => 10},
            [#{id => galileoskydec,
                start => {galileoskydec, start_link, []},
                restart => permanent,
                shutdown => 10000,
                type => worker,
                modules => [falileoskydec]},
             #{id => galileosky_pusher_sup,
                start => {galileosky_pusher_sup, start_link, []},
                restart => permanent,
                shutdown => 10000,
                type => supervisor,
                modules => [galileosky_pusher_sup]}
            ]}}.
