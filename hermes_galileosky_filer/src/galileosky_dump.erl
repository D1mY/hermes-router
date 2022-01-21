%%%% Galileosky devices packets dumper
%%%% Pull and push queues messages
-module (galileosky_dump).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

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

-define(Q_FILER, <<"hermes_galileosky_filer">>).

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
  %% subscribe to cfg queue
  Channel = intercourse(Connection, amqp_connection:open_channel(Connection)),
  ok = persistent_term:put({hermes_galileosky_filer,rabbitmq_channel},Channel),
  % #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"hermes.fanout">>, type = <<"fanout">>, passive = false, durable = true, auto_delete = false, internal = false}),
  % #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes">>, durable = true}),
  % #'queue.bind_ok'{} = amqp_channel:call(Channel,#'queue.bind'{queue = <<"hermes">>, exchange = <<"hermes.fanout">>}),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = ?Q_FILER, durable = true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = ?Q_FILER}, self()),
  %% loading stored cfg
  % read_cfg_file(cfg_path()),
  %% bgn listen cfg queue
  loop(Channel),
  %% ending
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
  rabbit_log:info("Hermes Galileosky filer close channel: ~p~n", [amqp_channel:close(Channel)]),
  persistent_term:erase({hermes_galileosky_filer,rabbitmq_channel}),
  rabbit_log:info("Hermes Galileosky filer close connection: ~p~n", [amqp_connection:close(Connection)]),
  rabbit_log:info("Hermes Galileosky filer ended",[]).

%%% cfg queue loop -------------------------------------------------------------
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
      dump_queues(Path); %% в Path ждем путь сохранения файлов дампа,
                           %% пустой бинарь - путь по умолчанию
    [{<<"restore">>,_,Path}] ->
      restore_queues(Path); %% в Path ждем путь файлов дампа,
                              %% пустой бинарь - путь по умолчанию
    _ -> 'not_valid'
  end.

%%% pull galileosky messages ---------------------------------------------------
dump_queues(Path) ->
  Qs = rabbit_amqqueue:list_names(), %% RabbitMQ internal, returns: [{resource,<<"vhost_name">>,queue,<<"queue_name">>}]
  handle_queues(Qs,Path).

handle_queues([], _) -> 'ok';
handle_queues(Qs, Path) ->
  [{resource,VNode,queue,Q}|QsTail] = Qs,
  case Q of
    ?Q_FILER ->
      'ok';
    _ ->
      %% (?) start supervisor with `all_significant` automatic shutdown
      handle_queue(VNode, Q, Path)
  end,
  handle_queues(QsTail, Path).

%% sub to Q, open file to write, spawn dump worker
handle_queue(VNode, Q, Path) ->
  Channel = persistent_term:get({hermes_galileosky_filer,rabbitmq_channel}),
  #'queue.declare_ok'{message_count = Count} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable = true}),
  case Count of
    0 ->
      'ok';
    _ ->
      File = parse_path(Path, VNode, Q),
      #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = Q}, self()), % Pid = erlang:spawn_link(?MODULE, dump_messages, [Count,Q,File])
      DlvrTag = dump_messages(Count, File),
      nack_msgs(Channel, DlvrTag),
      amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag})
  end.

dump_messages(Count, File) ->
  {ok, IoDevice} = file:open(File, [write, raw, delayed_write, binary]),
  DlvrTag = pull(Count, IoDevice, 0),
  file:close(IoDevice),
  DlvrTag.

pull(0,_,DlvrTag) ->
  DlvrTag;
pull(Count, IoDevice, DlvrTag) ->
  receive
    {#'basic.deliver'{delivery_tag = DlvrTag1}, Content} ->
      handle_message(Content, IoDevice),
      pull(Count - 1, IoDevice, DlvrTag1);
    _ -> pull(Count, IoDevice, DlvrTag)
  end.

handle_message(Content, IoDevice) ->
  [{<<"uid">>, _, DevUID}] = Content#amqp_msg.props#'P_basic'.headers,
  Payload = Content#amqp_msg.payload,
  file:write(IoDevice, erlang:term_to_binary({DevUID,Payload})).


%%% push galileosky messages ---------------------------------------------------
%% should act as `hermes_q_pusher`:
%  amqp_channel:call(AMQPChannel,
%                               #'basic.publish'{routing_key = DevUID},
%                               #amqp_msg{props = #'P_basic'{delivery_mode = 2, headers = [{<<"uid">>, longstr, DevUID}], content_encoding = <<"base64">>}, payload = [BinData]}
%                              )
%% DevUID must be in header, cause Galileosky device may translate packets from another Galileosky device
%% (!) TODO: cause input will grow up snowball-like, need to save last position
restore_queues(_Path) ->
  todo_push.

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
  case amqp_channel:call(Channel,#'basic.nack'{delivery_tag = DlvrTag, multiple = true, requeue = true}) of
    ok ->
      'ok';
      % loop(Channel);
    blocked ->
      timer:sleep(3000),
      nack_msgs(Channel, DlvrTag);
    closing ->
      {ok, <<"Closing channel">>}
  end.

parse_path(Path, _VNode, Q) ->
  case P = filelib:ensure_dir(erlang:binary_to_list(Path) ++ "/") of
    ok -> P ++ erlang:binary_to_list(Q);
    _ -> filename:join([filename:basedir(user_data,[]),"Hermes",erlang:node(),erlang:binary_to_list(Q)])
  end.