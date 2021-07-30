%% Decode Galileosky packets to JSON,
%% and pushing them to telegraf queue
-module(json_pusher).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

-export([
        start/1
        ]).

start(Q) when erlang:is_bitstring(Q) ->
  Connection = persistent_term:get({'hermes_json','rabbitmq_connection'}),
  Channel = intercourse(Connection, amqp_connection:open_channel(Connection)),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable = true}),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes_json">>, durable = true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = Q}, self()),
  loop(Channel),
  ok = amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag});
start(Any) ->
  rabbit_log:info("Hermes JSON wrong queue name format: ~p~n", [Any]).

intercourse(_, {ok, Res}) -> Res;
intercourse(X, {error, _}) ->
  timer:sleep(3000),
  intercourse(X, amqp_connection:open_channel(X)).

loop(Channel) ->
  receive
    #'basic.cancel_ok'{} ->
      {ok, <<"Cancel">>};
    {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
      Payload = erlang:binary_to_term(Content#amqp_msg.payload),
 %rabbit_log:info("Hermes debug Payload: ~p~n", [Payload]),
      JSON = handle_content([], Payload),
      publish_points(Channel, JSON, DlvrTag);
    %% Drop other not valid messages
    _ -> loop(Channel)
  end.

handle_content(Res, []) ->
 %rabbit_log:info("Hermes debug JSON: ~p~n", [Res]),
  %Res;
  jsone:encode(Res,[{float_format, [{decimals, 6}, compact]}]);
handle_content(Acc, Payload) ->
  %% Payload :: [{[{tag1,Val1},...,{tagN,ValN}]},...,{[{tag1,Val1},...,{tagN,ValN}]}]
  %% Cfg :: [{tag1,Fun1},...,{tagN,FunN}]
  [{Point}|Points] = Payload,
  PointMap = maps:from_list(Point),
 %rabbit_log:info("Hermes debug PointMap: ~p~n", [PointMap]),
  DevUID = maps:get(<<"dev_uid">>, PointMap, <<"">>),
  Cfg = persistent_term:get({'hermes_json', DevUID}, []),
 %rabbit_log:info("Hermes debug Cfg: ~p~n", [Cfg]),
  Res = apply_cfg(Cfg, PointMap),
  %Acc1 = [jsone:encode(Res,[{float_format, [{decimals, 6}, compact]}])|Acc],
  Acc1 = [Res|Acc],
  handle_content(Acc1, Points).

apply_cfg([], PointMap) ->
  PointMap;
apply_cfg([{Tag,{Fun}}|T], PointMap) ->
 %rabbit_log:info("Hermes debug Tag: ~p~n", [Tag]),
  case maps:is_key(Tag, PointMap) of
    true ->
      apply_cfg(T, maps:update_with(Tag, Fun, PointMap));
    false ->
      apply_cfg(T, PointMap)
  end.

publish_points(Channel, <<"[]">>, _) ->
  loop(Channel);
publish_points(Channel, Res, DlvrTag) ->
  case amqp_channel:call(Channel,
                         #'basic.publish'{exchange = <<>>, routing_key = <<"hermes_json">>},
                         #amqp_msg{props = #'P_basic'{delivery_mode = 2}, payload = Res}) of
    ok -> ack_points(Channel, DlvrTag);
    blocked -> timer:sleep(3000),
      publish_points(Channel, Res, DlvrTag);
    closing -> ok
  end.

ack_points(Channel, DlvrTag) ->
  case amqp_channel:call(Channel,#'basic.ack'{delivery_tag = DlvrTag}) of
    ok -> loop(Channel);
    blocked -> timer:sleep(3000),
      ack_points(Channel, DlvrTag);
    closing -> ok
  end.

