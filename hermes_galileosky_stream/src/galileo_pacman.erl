-module(galileo_pacman).

-export([
    start_link/2,
    packet_manager/2
]).

start_link(Socket, TimeOut) ->
    {ok, erlang:spawn_link(?MODULE, packet_manager, [Socket, TimeOut])}.

packet_manager(Socket, TimeOut) ->
    receive
        {get, CallersPid} ->
            %% вот тут оно зависнет до таймаута
            case gen_tcp:recv(Socket, 3, TimeOut) of
                {ok, <<Hdr:8, PSizeLst:8, AFlag:1, PSizeFrst:7>>} ->
                    <<PSize:16>> = <<PSizeFrst, PSizeLst>>,
                    case gen_tcp:recv(Socket, PSize + 2, 30000) of
                        {ok, <<BinData:PSize/binary, PCrc/binary>>} ->
                            Crc = crc17:calc(
                                <<Hdr:8, PSizeLst:8, AFlag:1, PSizeFrst:7, BinData/binary>>
                            ),
                            case Crc == PCrc of
                                true ->
                                    CallersPid ! {p_m, self(), Socket, Crc, BinData},
                                    packet_manager(Socket, 65535);
                                false ->
                                    gen_tcp:send(Socket, [<<2>>, Crc]),
                                    self() ! {get, CallersPid},
                                    packet_manager(Socket, TimeOut)
                            end;
                        Error ->
                            handle_error(Error, Socket, CallersPid, TimeOut)
                    end;
                Error ->
                    handle_error(Error, Socket, CallersPid, TimeOut)
            end;
        {abort, ok} ->
            rabbit_log:info("galileo pacman aborted, socket ~p~n", [Socket]);
        _ ->
            packet_manager(Socket, TimeOut)
    end,
    stop(Socket).

handle_error({error, timeout}, Socket, CallersPid, TimeOut) ->
    self() ! {get, CallersPid},
    %% рекурсия для проверки сообщений из "почтового ящика"
    packet_manager(Socket, TimeOut);
handle_error(Error, Socket, _, _) ->
    stop(Socket),
    rabbit_log:info("Socket ~p recv: ~p~n", [Socket, Error]).

stop(Socket) ->
    gen_tcp:close(Socket).
