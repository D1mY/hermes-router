-module(json_pusher_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    SupervisorSpecification = #{
        % one_for_one | one_for_all | rest_for_one | simple_one_for_one
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },

    ChildSpecifications = [
        #{
            id => json_pusher,
            start => {json_pusher, start_link, []},
            % permanent | transient | temporary
            restart => temporary,
            shutdown => 2000,
            % worker | supervisor
            type => worker,
            modules => [json_pusher]
        }
    ],

    {ok, {SupervisorSpecification, ChildSpecifications}}.
