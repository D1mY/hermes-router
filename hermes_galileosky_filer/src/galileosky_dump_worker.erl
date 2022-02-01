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
  {ok, Channel} = amqp_connection:open_channel(Connection),
  handle_queues(Qs, Path, Channel),
  amqp_channel:close(Channel),
  rabbit_log:info("Hermes Galileosky filer dump finished", []).

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
    0 ->  %% пустая очередь
      rabbit_log:info("dumper: ~p is empty",[Q]),
      'ok';
    _ ->  %% есть сообщения
      %% define file
      File = parse_path(Path, VNode, Q),
      %% sub to target queue
      #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = Q}, self()), % Pid = erlang:spawn_link(?MODULE, dump_messages, [Count,Q,File])
      rabbit_log:info("dumper: ~p have ~p, file ~p, consumer ~p",[Q,Count,File,ConsTag]),
      %% read queue messages
      DlvrTag = dump_messages(Count, File),
      %% nack readed messages
      nack_msgs(Channel, DlvrTag),
      %% unsub from target queue
      amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag})
  end.

dump_messages(Count, File) ->
  {ok, IoDevice} = file:open(File, [write, raw, delayed_write, binary]),
  DlvrTag = pull(Count, IoDevice, 0), %% ooops
  file:close(IoDevice),               %% careful
  DlvrTag.

pull(0,_,DlvrTag) ->
  DlvrTag;
pull(Count, IoDevice, DlvrTag) ->
  receive
    {#'basic.deliver'{delivery_tag = DlvrTag1}, Content} ->
      handle_message(Content, IoDevice),
      pull(Count - 1, IoDevice, DlvrTag1);
    _ ->
      pull(Count, IoDevice, DlvrTag)
  end.

handle_message(Content, IoDevice) ->
  case Content#amqp_msg.props#'P_basic'.headers of
    [{<<"uid">>, _, DevUID}] ->
      Payload = Content#amqp_msg.payload,
      Data = erlang:term_to_binary({DevUID,Payload}),
      DSize = erlang:size(Data),
      file:write(IoDevice, <<DSize:4/integer-unit:8, Data/binary>> );
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
restore_queues(Path) ->
  filelib:fold_files(
    Path,
    "^hermes_galileosky_qdump_",
    true,
    fun(File,_) ->
      case filelib:file_size(File) of
        0 ->
          'ok';
        _ ->
          rabbit_log:info("Hermes Galileosky filer: found dump ~p",[File]),
          Q = string:trim(File, leading, erlang:binary_to_list(Path) ++ "/hermes_galileosky_qdump_"),
          handle_file(File, Q)
      end
    end,
    []
  ),
  rabbit_log:info("Hermes Galileosky filer restore finished", []).

handle_file(File, Q) ->
  Connection = persistent_term:get({hermes_galileosky_filer,rabbitmq_connection}),
  {ok, Channel} = amqp_connection:open_channel(Connection),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable=true}),
  {ok, IoDevice} = file:open(File, [read, binary]),
  try
    handle_dump(IoDevice, Q, Channel)
  after
    file:close(IoDevice)
  end.

handle_dump(IoDevice, Q, Channel) ->
  case file:read(IoDevice, 4) of
    {ok, <<BinTermSize:4/integer-unit:8>>} ->
      {ok, Data} = file:read(IoDevice, BinTermSize),
      case erlang:binary_to_term(Data) of
        {DevUID, Payload} ->
          push(Channel, Q, DevUID, Payload),
          handle_dump(IoDevice, Q, Channel);
        _ ->
          'ok'
      end;
    eof -> 
      'ok'
  end.

push(Channel, Q, DevUID, Payload) ->
  amqp_channel:call(Channel,
                    #'basic.publish'{routing_key = Q},
                    #amqp_msg{props = #'P_basic'{delivery_mode = 2, headers = [{<<"uid">>, longstr, DevUID}], content_encoding = <<"base64">>}, payload = [Payload]}
                   ).

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
    ok -> P ++ "hermes_galileosky_qdump_" ++ erlang:binary_to_list(Q);
    _ -> filename:join([filename:basedir(user_data,[]),"Hermes",erlang:node(),"hermes_galileosky_qdump_" ++ erlang:binary_to_list(Q)])
  end.