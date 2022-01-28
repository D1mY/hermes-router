%%%% Galileosky devices packets dumper gen_server
%%% Осторожно: говнокод.
-module (galileosky_dump).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").
-include("include/filer.hrl").

-behaviour(gen_server).

-ifdef(EXPORTALL).
-compile(export_all).
-endif.

-export([start_link/0]).
-export([
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
        ]).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    rmq_connect().

%%%----------------------------------------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(_, State) ->
    {noreply,State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, {?MODULE, Port}) ->
    gen_tcp:close(Port),
    'ok'.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%----------------------------------------------------------------------------

rmq_connect() ->
  %% create RabbitMQ connection
  Connection = intercourse(?Q_FILER, amqp_connection:start(#amqp_params_direct{},?Q_FILER)),
  %% cmd channel
  Channel = intercourse(Connection, amqp_connection:open_channel(Connection)),
  ok = persistent_term:put({hermes_galileosky_filer,rabbitmq_connection}, Connection),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = ?Q_FILER, auto_delete = true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = ?Q_FILER}, self()),
  %% bgn listen cmd queue
  loop(Channel),
  %% ending
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
  rabbit_log:info("Hermes Galileosky filer close channel: ~p, ~p", [amqp_channel:close(Channel)]),
  persistent_term:erase({hermes_galileosky_filer,rabbitmq_connection}),
  rabbit_log:info("Hermes Galileosky filer close connection: ~p", [amqp_connection:close(Connection)]),
  rabbit_log:info("Hermes Galileosky filer ended",[]).

%%% cmd queue loop -------------------------------------------------------------
loop(Channel) ->
  receive
    {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
      handle_content(Content),
      ack_msg(Channel, DlvrTag);
    #'basic.cancel_ok'{} ->
      {ok, <<"Cancel">>};
    _ -> loop(Channel)
  end.

handle_content(Content) ->
  case Content#amqp_msg.props#'P_basic'.headers of
    [{<<"dump">>,_,Path}] ->
      start_worker(dump_queues, Path), %% в Path ждем путь сохранения файлов дампа,
                                       %% пустой бинарь - путь по умолчанию
      rabbit_log:info("Hermes Galileosky filer start dump to ~p",[Path]);
    [{<<"restore">>,_,Path}] ->
      start_worker(restore_queues, Path), %% в Path ждем путь файлов дампа,
                                          %% пустой бинарь - путь по умолчанию
      rabbit_log:info("Hermes Galileosky filer start restore from ~p",[Path]);
    _ -> 'not_valid'
  end.


%%%-----------------------------------------------------------------------------
%%% helpers
intercourse(_, {ok, Res}) -> Res;
intercourse(X, {error, _}) ->
  timer:sleep(3000),
  case erlang:is_bitstring(X) of
    true -> rmq_connect();
    false -> intercourse(X, amqp_connection:open_channel(X))
  end.

ack_msg(Channel, DlvrTag) ->
  case amqp_channel:call(Channel,#'basic.ack'{delivery_tag = DlvrTag}) of
    ok ->
      loop(Channel);
    blocked ->
      timer:sleep(3000),
      ack_msg(Channel, DlvrTag);
    closing ->
      {ok, <<"Closing channel">>}
  end.

start_worker(Action, Path) ->
  case lists:member(galileosky_dump_worker,erlang:registered()) of
    false ->
      erlang:register(galileosky_dump_worker,erlang:spawn_link(galileosky_dump_worker, Action, [Path]));
    true ->
      ok
  end.
