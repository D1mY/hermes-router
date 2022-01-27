%%%% Galileosky device packet dumpers worker
%%%% Pull and push queues messages
%%% Осторожно: говнокод.

-module (galileosky_dump_worker).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").
-include("include/filer.hrl").

-export([dump_queues/1, restore_queues/1]).

%%% pull galileosky messages ---------------------------------------------------
dump_queues(Path) ->
  Qs = rabbit_amqqueue:list_names(), %% RabbitMQ internal, returns: [{resource,<<"vhost_name">>,queue,<<"queue_name">>}]
  Connection = persistent_term:get({hermes_galileosky_filer,rabbitmq_connection}),
  Channel = amqp_connection:open_channel(Connection),
  rabbit_log:info("Workers channel: ~p", [Channel]),
  handle_queues(Qs, Path, Channel),
  amqp_channel:close(Channel).

handle_queues([], _, _) ->
  'ok';
handle_queues(Qs, Path, Channel) ->
  [{resource,VNode,queue,Q}|QsTail] = Qs,
  %% (?) start supervisor with `all_significant` automatic shutdown
  handle_queue(VNode, Q, Path, Channel),
  handle_queues(QsTail, Path, Channel).

%% sub to Q, open file to write, spawn dump worker
handle_queue(_, ?Q_FILER, _, _) ->
  'ok';
handle_queue(VNode, Q, Path, Channel) ->
  #'queue.declare_ok'{message_count = Count} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, passive = true}),
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
  case Content#amqp_msg.props#'P_basic'.headers of
    [{<<"uid">>, _, DevUID}] ->
      Payload = Content#amqp_msg.payload,
      file:write(IoDevice, erlang:term_to_binary({DevUID,Payload}));
    _ ->
      'ok'
    end.

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
nack_msgs(Channel, DlvrTag) ->
  case amqp_channel:call(Channel,#'basic.nack'{delivery_tag = DlvrTag, multiple = true, requeue = true}) of
    ok ->
      'ok';
    blocked ->
      timer:sleep(3000),
      nack_msgs(Channel, DlvrTag);
    closing ->
      {ok, <<"Closing channel">>}
  end.

parse_path(Path, _VNode, Q) ->
  P = erlang:binary_to_list(Path) ++ "/",
  case filelib:ensure_dir(P) of
    ok -> P ++ erlang:binary_to_list(Q);
    _ -> filename:join([filename:basedir(user_data,[]),"Hermes",erlang:node(),erlang:binary_to_list(Q)])
  end.