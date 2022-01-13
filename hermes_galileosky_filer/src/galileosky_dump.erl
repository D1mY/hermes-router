%%%% Galileosky protocol default decoder
%%%% User's protocol over Galileosky protocol listener
-module (galileoskydec).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

-behaviour(gen_server).

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
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%----------------------------------------------------------------------------

rmq_connect() ->
  %% create RabbirMQ connection for self() and spawn_link() prcss
  Connection = intercourse(<<"hermes_galileosky_filer">>, amqp_connection:start(#amqp_params_direct{},<<"hermes_galileosky_filer">>)),
  % ok = persistent_term:put({hermes_galileosky_broker,rabbitmq_connection},Connection),
  %% subscribe to cfg queue
  Channel = intercourse(Connection, amqp_connection:open_channel(Connection)),
  % #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"hermes.fanout">>, type = <<"fanout">>, passive = false, durable = true, auto_delete = false, internal = false}),
  % #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes">>, durable = true}),
  % #'queue.bind_ok'{} = amqp_channel:call(Channel,#'queue.bind'{queue = <<"hermes">>, exchange = <<"hermes.fanout">>}),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes_galileosky_filer">>, durable = true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = <<"hermes_galileosky_filer">>}, self()),
  %% loading stored cfg
  % read_cfg_file(cfg_path()),
  %% bgn listen cfg queue
  loop(Channel),
  %% ending
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
  rabbit_log:info("Hermes Galileosky filer close channel: ~p~n", [amqp_channel:close(Channel)]),
  rabbit_log:info("Hermes Galileosky filer close connection: ~p~n", [amqp_connection:close(Connection)]),
  % persistent_term:erase({hermes_galileosky_broker,rabbitmq_connection}),
  rabbit_log:info("Hermes Galileosky filer ended",[]).

%%% cfg queue loop
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
    [{<<"dump">>,_,HValue}] ->
      dump_queues(HValue); %% в HValue ждем путь сохранения файлов дампа,
                           %% пустой бинарь - путь по умолчанию
    [{<<"restore">>,_,HValue}] ->
      restore_queues(HValue); %% в HValue ждем путь файлов дампа,
                              %% пустой бинарь - путь по умолчанию
    _ -> 'not_valid'
  end.

dump_queues(Path) ->

  dump_queues(QList);
dump_queues(QList) -> 
  [Q|QListTail] = QList,
  #'queue.declare_ok'{message_count = Count} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable = true}),
  dump_messages(Count),
  dump_queues(QListTail).

dump_messages(0) -> ok;
dump_messages(Count) -> dump_messages(Count - 1).

restore_queues(Path) -> ok.

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

nack_msgs(Channel, DlvrTag) ->
  case amqp_channel:call(Channel,#'basic.nack'{delivery_tag = DlvrTag, multiplie = true, requeue = true}) of
    ok ->
      ok;
      % loop(Channel);
    blocked ->
      timer:sleep(3000),
      nack_msgs(Channel, DlvrTag);
    closing ->
      {ok, <<"Closing channel">>}
  end.