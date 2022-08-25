%%%-------------------------------------------------------------------
%% @doc galileosky_pusher supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(galileosky_pusher_sup).

-behaviour(supervisor).

-define(DEBUGMODE, false).

-export([start_link/0, init/1]).

start_link() ->
    Res = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    sys:trace(galileosky_pusher_sup, ?DEBUGMODE),
    erlang:spawn_link(fun() -> start_workers() end),
    Res.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 3,
            period => 10},
            []}}.

start_workers() ->
case erlang:whereis(galileoskydec) of
    undefined ->
        timer:sleep(1000),
        start_workers();
    Pid ->
        gen_server:cast(Pid, restore_cfg)
    end.