-module(hermes_accept_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_worker/2]).
-export([init/1]).

start_link() ->
    Res = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    sys:trace(hermes_accept_sup, true),
    erlang:spawn_link(fun() -> start_workers() end),
    Res.

init(_Args) ->
    SupervisorSpecification = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60},

    ChildSpecifications = [
        #{
            id => hermes_accept,
            start => {hermes_accept_sup, start_worker, []},
            restart => permanent,
            shutdown => 2000,
            type => worker,
            modules => [hermes_worker]
        }
    ],

    {ok, {SupervisorSpecification, ChildSpecifications}}.

start_workers() ->
case erlang:whereis(hermes_worker) of
    undefined ->
        timer:sleep(1000),
        start_workers();
    Pid ->
        gen_server:cast(Pid, start_acceptors)
    end.

start_worker(Id, ListenSocket) ->
    Pid = erlang:spawn_link(hermes_worker, accept, [Id, ListenSocket]),
    {ok, Pid}.