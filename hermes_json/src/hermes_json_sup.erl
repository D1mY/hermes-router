%%%-------------------------------------------------------------------
%% @doc hermes_json top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(hermes_json_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok,
        {
            #{
                strategy => rest_for_one,
                intensity => 3,
                period => 10
            },
            [
                #{
                    id => hermesenc,
                    start => {hermesenc, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker,
                    modules => [hermesenc]
                },
                #{
                    id => json_pusher_sup,
                    start => {json_pusher_sup, start_link, []},
                    restart => permanent,
                    shutdown => 10000,
                    type => supervisor,
                    modules => [json_pusher_sup, jsone]
                }
            ]
        }}.
