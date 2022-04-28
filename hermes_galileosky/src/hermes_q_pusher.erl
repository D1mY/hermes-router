-module(hermes_q_pusher).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

-export([
    start_link/1,
    q_pusher_init/1
]).

start_link(DevUID) ->
    {ok, erlang:spawn_link(?MODULE, q_pusher_init, [DevUID])}.

%% инит пихателя в очередь
q_pusher_init(DevUID) ->
    {PMPid, AMQPConnection} = gen_server:call(hermes_worker, {init_qpusher, DevUID}),
    q_pusher_init(DevUID, PMPid, AMQPConnection).
q_pusher_init(_, undefined, _) ->
    ok;
q_pusher_init(DevUID, PMPid, AMQPConnection) ->
    %,arguments=[{<<"x-queue-mode">>,longstr,<<"lazy">>}]}), %% maybe needed "lazy queues" 4 low RAM hardware
    {ok, AMQPChannel} = amqp_connection:open_channel(AMQPConnection),
    #'queue.declare_ok'{} = amqp_channel:call(AMQPChannel, #'queue.declare'{
        queue = DevUID, durable = true
    }),
    % amqp_channel:register_flow_handler(AMQPChannel, self()),
    q_pusher(DevUID, PMPid, AMQPConnection, AMQPChannel).

%% пихатель в очередь (свою для каждого устройства), единственный для каждого устройства.
q_pusher(DevUID, CurrPMPid, AMQPConnection, AMQPChannel) ->
    receive
        {p_m, PMPid, Socket, Crc, BinData} ->
            case q_push(AMQPChannel, DevUID, BinData) of
                ok ->
                    gen_tcp:send(Socket, [<<2>>, Crc]),
                    PMPid ! {get, self()},
                    q_pusher(DevUID, CurrPMPid, AMQPConnection, AMQPChannel);
                blocked ->
                    timer:sleep(1000),
                    PMPid ! {get, self()},
                    q_pusher(DevUID, CurrPMPid, AMQPConnection, AMQPChannel);
                closing ->
                    close_all(DevUID, AMQPChannel)
            end;
        {new_socket, NewPMPid, BinData} ->
            case q_push(AMQPChannel, DevUID, BinData) of
                ok ->
                    NewPMPid ! {get, self()},
                    case CurrPMPid == NewPMPid of
                        true ->
                            ok;
                        false ->
                            CurrPMPid ! {abort, ok}
                    end,
                    q_pusher(DevUID, NewPMPid, AMQPConnection, AMQPChannel);
                blocked ->
                    timer:sleep(1000),
                    self() ! {new_socket, NewPMPid, BinData},
                    q_pusher(DevUID, CurrPMPid, AMQPConnection, AMQPChannel);
                closing ->
                    close_all(DevUID, AMQPChannel)
            end;
        Any ->
            rabbit_log:info("qpusher ~p recieved: ~p~n", [DevUID, Any]),
            q_pusher(DevUID, CurrPMPid, AMQPConnection, AMQPChannel)
    after 666000 ->
        close_all(DevUID, AMQPChannel)
    end.

q_push(AMQPChannel, DevUID, BinData) ->
    amqp_channel:call(
        AMQPChannel,
        #'basic.publish'{routing_key = DevUID},
        #amqp_msg{
            props = #'P_basic'{
                delivery_mode = 2,
                headers = [{<<"uid">>, longstr, DevUID}],
                content_encoding = <<"base64">>
            },
            payload = [BinData]
        }
    ).

close_all(DevUID, AMQPChannel) ->
    gen_server:call(hermes_worker, {stop_pacman, DevUID}),
    rabbit_log:info("qpusher ended: AMQP channel ~p closing~n", [AMQPChannel]),
    % amqp_channel:unregister_flow_handler(AMQPChannel),
    amqp_channel:close(AMQPChannel).
