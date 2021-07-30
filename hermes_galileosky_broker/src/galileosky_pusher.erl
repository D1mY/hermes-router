%%% Decode Galileosky packets to Erlang terms,
%%% and pushing them to ebtq queue
-module(galileosky_pusher).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

-export([
        start/1
        ]).

start(Q) when erlang:is_bitstring(Q) ->
  packet_decoder(Q);
start(Any) ->
  rabbit_log:info("Hermes Galileosky pusher ~p wrong queue name format: ~p~n", [erlang:process_info(self(), registered_name),Any]).

packet_decoder({not_found, Q}) ->
  rabbit_log:info("Hermes Galileosky connection not found by pusher for ~p~n",[Q]);
packet_decoder(Q) ->
  case Connection = persistent_term:get({hermes_galileosky_broker,rabbitmq_connection}, not_found) of
    not_found -> packet_decoder({not_found, Q});
    _ -> ok
  end,
  Channel = intercourse(Q, Connection, amqp_connection:open_channel(Connection)),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable=true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = Q}, self()),
  loop(Channel, []),
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
  rabbit_log:info("Hermes Galileosky pusher ~p channel close: ~p~n", [Q, amqp_channel:close(Channel)]).

intercourse(_, _, {ok, Channel}) -> Channel;
intercourse(Q, Connection, {error, _}) ->
  timer:sleep(1000),
  intercourse(Q, Connection, amqp_connection:open_channel(Connection,1)).

loop(Channel, CfgMap) ->
  receive
    {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
      % IMEI ("uid") should be in header
      Res = handle_content(Content, CfgMap),
      case publish_points(Channel, erlang:term_to_binary(Res, [compressed]), DlvrTag) of
        ok -> loop(Channel, CfgMap);
        Any -> Any
      end;
    {cfg,Payload} -> % {cfg,_} received first of all
      handle_cfg(Channel, Payload);
    {stop,CallersPid} ->
      rabbit_log:info("Hermes Galileosky pusher ~p stopped by broker ~p~n", [erlang:process_info(self(), registered_name),CallersPid]);
    #'basic.cancel_ok'{} ->
      {ok, <<"Cancel">>};
     % Drop other not valid messages
    _ -> loop(Channel, CfgMap)
  end.

handle_cfg(Channel, Payload) ->
  CfgMap = maps:merge(maps:from_list(ets:tab2list(galskytags)), maps:from_list(Payload)),
  loop(Channel, CfgMap).

handle_content(Content, CfgMap) ->
  case Content#amqp_msg.props#'P_basic'.headers of
    [{<<"uid">>, _, DevUID}] ->
      Payload = Content#amqp_msg.payload,
      push_data(CfgMap, Payload, 0, DevUID, [], []);
    _ ->
      not_valid
  end.

publish_points(_, not_valid, _) ->
  ok;
publish_points(Channel, Res, DlvrTag) ->
  case amqp_channel:call(Channel,
                         #'basic.publish'{exchange = <<"hermes.fanout">>, routing_key = <<"hermes">>},
                         #amqp_msg{props = #'P_basic'{delivery_mode = 2}, payload = Res}) of
    ok -> ack_points(Channel, DlvrTag);
    blocked -> timer:sleep(3000),
      publish_points(Channel, Res, DlvrTag);
    closing -> closing
  end.

ack_points(Channel, DlvrTag) ->
  case amqp_channel:call(Channel,#'basic.ack'{delivery_tag = DlvrTag}) of
    ok -> ok;
    blocked -> timer:sleep(3000),
      ack_points(Channel, DlvrTag);
    closing -> closing
  end.

push_data(_, <<>>, _, DevUID, Acc, []) -> % message of 1 point
  [{lists:flatten(Acc,[{<<"dev_uid">>,DevUID}])}];
push_data(_, <<>>, _, DevUID, Acc, TArr) -> % message of many points
  [{lists:flatten(Acc,[{<<"dev_uid">>,DevUID}])}|TArr];
push_data(CfgMap, Payload, PrevTag, DevUID, Acc, TArr) ->
  <<Tag:8,Tail/binary>> = Payload,
  case Tag >= PrevTag of
    true -> % accumulate new line of terms
      case maps:get(Tag, CfgMap, not_found) of
        {Len, ExtractFun} ->
          <<Data:Len/binary,Tail1/binary>> = Tail,
          push_data(CfgMap, Tail1, Tag, DevUID, [ExtractFun(Data)|Acc], TArr);
        not_found-> 
          push_data(CfgMap, <<>>, Tag, DevUID, [{lists:flatten(Acc,[{<<"unknown_galileosky_protocol_tag">>,Tag}])}], TArr)
      end;
    false -> % lot of points in message
      push_data(CfgMap, Payload, 0, DevUID, [], [{lists:flatten(Acc,[{<<"dev_uid">>,DevUID}])}|TArr])
  end.
