%%% Decode Galileosky packets to Erlang terms,
%%% and pushing them to ebtq queue
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
        erlang:process_info(self(), registered_name), Any
    ]).

init(Q) ->
    % bad practice?
    process_flag(trap_exit, true),
    PuName = erlang:binary_to_atom(<<"galileosky_pusher_", Q/binary>>),
    erlang:register(PuName, self()),
    CfgPath = gen_server:call(galileoskydec, get_cfg_path),
    Cfg = read_cfg_file(CfgPath, Q),
    self() ! {cfg, Cfg},
    Connection = gen_server:call(galileoskydec, get_connection),
    Channel = gen_server:call(galileoskydec, {get_channel, PuName}),
    % Channel = intercourse(Q, Connection, amqp_connection:open_channel(Connection)),
    % #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = Q, durable = true}),
    % #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:call(Channel, #'basic.consume'{
    %     queue = Q
    % }),
    loop(Channel, []),
    % case erlang:is_process_alive(Channel) of
    %     true ->
    %         amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
    %         rabbit_log:info("Hermes Galileosky pusher ~p channel close: ~p", [
    %             Q, amqp_channel:close(Channel)
    %         ]);
    %     _ ->
    %         ok
    % end,
    ok.

loop(Channel, CfgMap) ->
    receive
        {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
            % IMEI ("uid") should be in header
            Res = handle_content(Content, CfgMap),
            case publish_points(Channel, Res, DlvrTag) of
                ok -> loop(Channel, CfgMap);
                Any -> Any % TODO: handle this
            end;
        {cfg, Payload} ->
            CfgMap1 = maps:merge(maps:from_list(ets:tab2list(galskytags)), maps:from_list(Payload)),
            loop(Channel, CfgMap1);
        % {'EXIT', _From, Reason} ->
        %     {registered_name, PuName} = erlang:process_info(self(), registered_name),
        %     rabbit_log:info("Hermes Galileosky pusher ~p stopped with reason ~p", [
        %         PuName, Reason
        %     ]),
        %     gen_server:cast(galileoskydec, {stop_pusher, PuName});
        #'basic.cancel_ok'{} ->
            ok;
            % erlang:exit();
        _ ->
            loop(Channel, CfgMap)
    end.

handle_content(Content, CfgMap) ->
    case Content#amqp_msg.props#'P_basic'.headers of
        [{<<"uid">>, _, DevUID}] ->
            Payload = Content#amqp_msg.payload,
            Res = parse_data(CfgMap, Payload, 0, DevUID, [], []),
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
            timer:sleep(3000),
            publish_points(Channel, Res, DlvrTag);
        closing ->
            closing
    end.

% message of 1 point
parse_data(_, <<>>, _, DevUID, Acc, []) ->
    [{lists:flatten(Acc, [{<<"dev_uid">>, DevUID}])}];
% message of many points
parse_data(_, <<>>, _, DevUID, Acc, TArr) ->
    [{lists:flatten(Acc, [{<<"dev_uid">>, DevUID}])} | TArr];
parse_data(CfgMap, Payload, PrevTag, DevUID, Acc, TArr) ->
    <<Tag:8, Tail/binary>> = Payload,
    case Tag >= PrevTag of
        % accumulate new line of terms
        true ->
            case maps:get(Tag, CfgMap, not_found) of
                {Len, ExtractFun} ->
                    <<Data:Len/binary, Tail1/binary>> = Tail,
                    parse_data(CfgMap, Tail1, Tag, DevUID, [ExtractFun(Data) | Acc], TArr);
                not_found ->
                    parse_data(
                        CfgMap,
                        <<>>,
                        Tag,
                        DevUID,
                        [{lists:flatten(Acc, [{<<"unknown_galileosky_protocol_tag">>, Tag}])}],
                        TArr
                    )
            end;
        % lot of points in message
        false ->
            parse_data(CfgMap, Payload, 0, DevUID, [], [
                {lists:flatten(Acc, [{<<"dev_uid">>, DevUID}])} | TArr
            ])
    end.

%%%-----------------------------------------------------------------------------
%%% helpers
intercourse(_, _, {ok, Channel}) ->
    Channel;
intercourse(Q, Connection, {error, _}) ->
    timer:sleep(1000),
    intercourse(Q, Connection, amqp_connection:open_channel(Connection)).

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
        ok ->
            ok;
        blocked ->
            timer:sleep(3000),
            ack_points(Channel, DlvrTag);
        closing ->
            closing
    end.
