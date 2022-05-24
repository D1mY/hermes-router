-module(galileo_pacman_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    erlang:spawn_link(fun() -> init_ets() end),
    SupervisorSpecification = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },

    ChildSpecifications = [
        #{
            id => galileo_pacman,
            start => {galileo_pacman, start_link, []},
            % permanent | transient | temporary
            restart => temporary,
            shutdown => 2000,
            % worker | supervisor
            type => worker,
            modules => [galileo_pacman]
        }
    ],

    {ok, {SupervisorSpecification, ChildSpecifications}}.

init_ets() ->
    case erlang:whereis(hermes_worker) of
        undefined ->
            timer:sleep(1000),
            init_ets();
        Pid ->
            gen_server:call(Pid, init_ets_table)
    end.
