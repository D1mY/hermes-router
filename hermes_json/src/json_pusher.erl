%% Decode Galileosky packets to JSON,
%% and pushing them to telegraf queue
-module(json_pusher).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

-export([
    start_link/1,
    start/1
]).

start_link(Q) ->
    {ok, erlang:spawn_link(?MODULE, start, [Q])}.

start(Q) when erlang:is_bitstring(Q) ->
    Connection = gen_server:call(hermesenc, get_connection),
    start(Q, Connection);
start(Any) ->
    rabbit_log:info("Hermes JSON wrong queue name format: ~p~n", [Any]).
start(Q, Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable = true}),
    #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{
        queue = <<"hermes_json">>, durable = true
    }),
    #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(
        Channel, #'basic.consume'{queue = Q}, self()
    ),
    loop(Channel),
    ok = amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}).

loop(Channel) ->
    receive
        #'basic.cancel_ok'{} ->
            {ok, <<"Cancel">>};
        {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
            Payload = erlang:binary_to_term(Content#amqp_msg.payload),
            JSON = handle_content([], Payload),
            publish_points(Channel, JSON, DlvrTag);
        %% Drop other not valid messages
        _ ->
            loop(Channel)
    end.

handle_content(Res, []) ->
    thoas:encode(Res);
handle_content(Acc, Payload) ->
    %% Payload :: [{[{tag1,Val1},...,{tagN,ValN}]},...,{[{tag1,Val1},...,{tagN,ValN}]}]
    %% Cfg :: [{tag1,Fun1},...,{tagN,FunN}]
    [{Point} | Points] = Payload,
    PointMap = maps:from_list(Point),
    DevUID = maps:get(<<"dev_uid">>, PointMap, <<"">>),
    Cfg = persistent_term:get({'hermes_json', DevUID}, []),
    Res = apply_cfg(Cfg, PointMap),
    Acc1 = [Res | Acc],
    handle_content(Acc1, Points).

apply_cfg([], PointMap) ->
    PointMap;
apply_cfg([{Tag, {Fun}} | T], PointMap) ->
    case maps:is_key(Tag, PointMap) of
        true ->
            apply_cfg(T, maps:update_with(Tag, Fun, PointMap));
        false ->
            apply_cfg(T, PointMap)
    end.

publish_points(Channel, <<"[]">>, _) ->
    loop(Channel);
publish_points(Channel, Res, DlvrTag) ->
    case
        amqp_channel:call(
            Channel,
            #'basic.publish'{exchange = <<>>, routing_key = <<"hermes_json">>},
            #amqp_msg{props = #'P_basic'{delivery_mode = 2}, payload = Res}
        )
    of
        ok ->
            ack_points(Channel, DlvrTag);
        blocked ->
            timer:sleep(3000),
            publish_points(Channel, Res, DlvrTag);
        closing ->
            ok
    end.

ack_points(Channel, DlvrTag) ->
    case amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DlvrTag}) of
        ok ->
            loop(Channel);
        blocked ->
            timer:sleep(3000),
            ack_points(Channel, DlvrTag);
        closing ->
            ok
    end.
