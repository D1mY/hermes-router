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
    Res.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 3,
            period => 10},
            []}}.