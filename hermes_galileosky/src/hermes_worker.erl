-module(hermes_worker).
-behaviour(gen_server).

-export([start_link/0]).
-export([
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
        ]).
-export([
        server/1,
        % start_acceptor/2,
        accept/2
        ]).

-define(PROCNUM, 9). %% Кол-во ожидающих accept-ов минус один

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    State = server(application:get_env(hermes_galileosky, tcp_port, 60521)), %% запускаем сервер при старте плагина на порту из конфига (или дефолт: 60521)
    {ok, State}.

%----------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(start_acceptors, State) ->
    [supervisor:start_child(hermes_accept_sup, [Id, State]) || Id <- lists:seq(0, ?PROCNUM)],
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, {?MODULE, Port}) ->
    gen_tcp:close(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%----------------------------------------------
%% запускаем сервер
server(Port) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary,{active,false},{reuseaddr,true},{exit_on_close,true},{keepalive,false},{nodelay,true},{backlog,128}]),
    rabbit_log:info("Started Hermes Galileosky server at port ~p", [Port]), %% чокаво
    ListenSocket.

accept(Id, ListenSocket) -> %% прием TCP соединения от устройства
    rabbit_log:info("Hermes Galileosky server: acceptor #~p wait for client", [Id]), %% чокаво
    %% TODO: guard
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    %% -----------
    rabbit_log:info("Hermes Galileosky server: acceptor #~p: client connected on socket ~p", [Id, Socket]), %% чокаво
    %% TODO: guard
    {ok, PMPid} = supervisor:start_child(galileo_pacman_sup, [Socket, 61000]),
    %% -----------
    % PMPid = erlang:spawn(galileo_pacman, packet_manager, [Socket, 61000]),
    case gen_tcp:controlling_process(Socket, PMPid) of
        ok ->
            PMPid ! {get, self()}, %% у родившегося pacman-а запрашиваем пакет от девайса
            receive
                {p_m, PMPid, Socket, Crc, BinData} -> %% принят ответ от рожденного pacman-а
                    case packet_getid(BinData) of
                        ok -> %% UID девайса нот детектед
                            PMPid ! {abort, ok}; %% яваснезвалидитенайух
                        Dev_UID -> %% UID девайса детектед
                            gen_tcp:send(Socket, [<<2>>, Crc]), %% отправляем ответный CRC
                            handle_socket(Dev_UID, PMPid, BinData), %% приступаем к водным процедурам
                            rabbit_log:info("Hermes Galileosky server: acceptor #~p: client ~p, device UID=~p, pacman PID=~p, socket ~p", [Id, inet:peername(Socket), Dev_UID, PMPid, Socket]) %% чокаво
                    end;
                Any ->
                    rabbit_log:info("Hermes Galileosky server: acceptor #~p get ~p",[Id,Any])
            after 60000 ->
                rabbit_log:info("Hermes Galileosky server: acceptor #~p timeout: client ~p, pacman PID=~p, socket ~p~n", [Id, inet:peername(Socket), PMPid, Socket]), %% чокаво
                PMPid ! {abort, ok},
                gen_tcp:close(Socket)
            end;
        {error, _} ->
            gen_tcp:close(Socket)
    end,
  accept(Id, ListenSocket).

handle_socket(Dev_UID, PMPid, BinData) -> %% ищем запущенный или рожаем новый обработчик данных от девайса.
    case erlang:whereis(erlang:binary_to_atom(Dev_UID, latin1)) of
        undefined -> %% новый девайс
            erlang:spawn(hermes_q_pusher,q_pusher_init,[Dev_UID, PMPid]) ! {new_socket, PMPid, BinData},
            rabbit_log:info("Hermes Galileosky server: new qpusher for uid=~p pacman pid=~p", [Dev_UID, PMPid]); %% чокаво;
        QPPid -> %% девайс переподключился на новый сокет
            QPPid ! {new_socket, PMPid, BinData},
            rabbit_log:info("Hermes Galileosky server: found qpusher ~p: new pacman pid=~p for uid=~p", [QPPid, PMPid, Dev_UID]) %% чокаво
    end.

packet_getid(<<>>) ->
    ok; %% no IMEI tag found
packet_getid(BinData) when erlang:is_binary(BinData) ->
    <<Tag:8, REst/binary>> = BinData,
    case Tag == 3 of
        false ->
            <<_:1/binary, Est/binary>> = REst,
            packet_getid(Est);
        true ->
            <<Dev_UID:120/bits, _/bits>> = REst,
            Dev_UID
    end.