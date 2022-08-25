%%% Decode Galileosky packets to Erlang terms,
%%% and pushing them to RMQ exchange
-module(galileosky_pusher).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

-export([
    start/1,
    init/1
]).

start(Q) when erlang:is_bitstring(Q) ->
    {ok, erlang:spawn_link(?MODULE, init, [Q])};
start(Any) ->
    rabbit_log:info("Hermes Galileosky pusher ~p wrong queue name format: ~p", [
        self(), Any
    ]).

init(Q) ->
    CfgPath = gen_server:call(galileoskydec, get_cfg_path),
    Cfg = read_cfg_file(CfgPath, Q),
    self() ! {cfg, Cfg},
    Channel = gen_server:call(galileoskydec, {get_channel, Q}),
    loop(Channel, []),
    ok.

loop(Channel, CfgMap) ->
    receive
        {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
            %% IMEI ("uid") should be in header
            Res = handle_content(Content, CfgMap),
            case publish_points(Channel, Res, DlvrTag) of
                ok -> loop(Channel, CfgMap);
                %% TODO: handle this
                Any -> Any
            end;
        {cfg, Payload} ->
            CfgMap1 = maps:merge(maps:from_list(ets:tab2list(galskytags)), maps:from_list(Payload)),
            loop(Channel, CfgMap1);
        #'basic.consume_ok'{consumer_tag = ConsTag} ->
            erlang:put(consumer_tag, ConsTag),
            loop(Channel, CfgMap);
        #'basic.cancel_ok'{consumer_tag = ConsTag} ->
            case ConsTag == erlang:get(consumer_tag) of
                true ->
                    ok;
                false ->
                    loop(Channel, CfgMap)
            end;
        _ ->
            loop(Channel, CfgMap)
    end.

handle_content(Content, CfgMap) ->
    case Content#amqp_msg.props#'P_basic'.headers of
        [
            {<<"uid">>, _, DevUID},
            {<<"x-stream-offset">>, long, MsgOffset}
        ] ->
            Payload = Content#amqp_msg.payload,
            Res = parse_data(CfgMap, Payload, 0, DevUID, [], []),
            save_offset(MsgOffset),
            erlang:term_to_binary(Res, [compressed]);
        _ ->
            not_valid
    end.

publish_points(_, not_valid, _) ->
    ok;
publish_points(Channel, Res, DlvrTag) ->
    case
        amqp_channel:call(
            Channel,
            #'basic.publish'{exchange = <<"hermes.fanout">>, routing_key = <<"hermes">>},
            #amqp_msg{props = #'P_basic'{delivery_mode = 2}, payload = Res}
        )
    of
        ok ->
            ack_points(Channel, DlvrTag);
        blocked ->
            timer:sleep(1000),
            publish_points(Channel, Res, DlvrTag);
        closing ->
            closing
    end.

%% message of 1 point
parse_data(_, <<>>, _, DevUID, Acc, []) ->
    [{lists:flatten(Acc, [{<<"dev_uid">>, DevUID}])}];
%% message of many points
parse_data(_, <<>>, _, DevUID, Acc, TArr) ->
    [{lists:flatten(Acc, [{<<"dev_uid">>, DevUID}])} | TArr];
parse_data(CfgMap, Payload, PrevTag, DevUID, Acc, TArr) ->
    <<Tag:8, Tail/binary>> = Payload,
    case Tag >= PrevTag of
        %% accumulate new line of terms
        true ->
            case maps:get(Tag, CfgMap, not_found) of
                {Len, ExtractFun} ->
                    Len1 = parse_len(Len, Tail),
                    <<Data:Len1/binary, Tail1/binary>> = Tail,
                    parse_data(CfgMap, Tail1, Tag, DevUID, [ExtractFun(Data) | Acc], TArr);
                not_found ->
                    parse_data(
                        CfgMap,
                        <<>>,
                        Tag,
                        DevUID,
                        [{<<"unknown_galileosky_protocol_tag">>, Tag} | Acc],
                        TArr
                    )
            end;
        %% lot of points in message
        false ->
            parse_data(CfgMap, Payload, 0, DevUID, [], [
                {lists:flatten(Acc, [{<<"dev_uid">>, DevUID}])} | TArr
            ])
    end.

parse_len(Size, Data) when erlang:is_integer(Size) ->
    Size;
parse_len(SizeFun, Data) ->
    SizeFun(Data).

save_offset(Offset) -> ok.

%%%-----------------------------------------------------------------------------
%%% helpers
read_cfg_file(error, _) ->
    [];
read_cfg_file(Path, Q) ->
    File = Path ++ "/hermes_galileosky_" ++ erlang:binary_to_list(Q),
    case file:read_file(File) of
        {ok, T} ->
            %% TODO: enshure T is list in binary
            erlang:binary_to_term(T);
        {error, Reason} ->
            rabbit_log:info("Hermes Galileosky pusher: cfg ~p read error: ~p", [
                File, Reason
            ]),
            read_cfg_file(error, Reason)
    end.

ack_points(Channel, DlvrTag) ->
    case amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DlvrTag}) of
        blocked ->
            timer:sleep(1000),
            ack_points(Channel, DlvrTag);
        _ ->
            ok
    end.
