-module(hermes_q_pusher_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([init/1]).

start_link() ->
    Res = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    erlang:spawn_link(fun() -> start_workers() end),
    Res.

init(_Args) ->
    SupervisorSpecification = #{
        strategy => simple_one_for_one, % one_for_one | one_for_all | rest_for_one | simple_one_for_one
        intensity => 10,
        period => 60},

    ChildSpecifications = [
        #{
            id => hermes_q_pusher,
            start => {hermes_q_pusher, start_link, []},
            restart => transient, % permanent | transient | temporary
            shutdown => 2000,
            type => worker, % worker | supervisor
            modules => [hermes_q_pusher]
        }
    ],

    {ok, {SupervisorSpecification, ChildSpecifications}}.

start_workers() ->
case erlang:whereis(hermes_worker) of
    undefined ->
        timer:sleep(1000),
        start_workers();
    Pid ->
        gen_server:cast(Pid, start_qpushers)
    end.