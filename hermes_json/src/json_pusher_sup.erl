-module(json_pusher_sup).

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
            restart => transient,
            shutdown => 2000,
            % worker | supervisor
            type => worker,
            modules => [json_pusher, jsone]
        }
    ],

    {ok, {SupervisorSpecification, ChildSpecifications}}.

start_workers() ->
    case erlang:whereis(hermesenc) of
        undefined ->
            timer:sleep(1000),
            start_workers();
        Pid ->
            gen_server:cast(Pid, start_json_pushers)
    end.
