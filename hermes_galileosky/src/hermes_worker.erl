-module(hermes_worker).

-include_lib("../deps/amqp_client/include/amqp_client.hrl").

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
        accept/2
        ]).

-define(PROCNUM, 9). %% Кол-во ожидающих accept-ов минус один

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    State = server(application:get_env(hermes_galileosky, tcp_port, 60521)), %% запускаем сервер при старте плагина на порту из конфига (или дефолт: 60521)
    {ok, State}.

%%%----------------------------------------------------------------------------
handle_call({handle_qpusher, DevUID, Action}, From, State) ->
    {QPPid, _} = From,
    Reply = case Action of
        put ->
            QPPid = supervisor:start_child(hermes_q_pusher_sup, [DevUID]),
            erlang:put(erlang:binary_to_atom(DevUID, latin1), QPPid),
            QPPid;
        get ->
            erlang:get(erlang:binary_to_atom(DevUID, latin1));
        erase ->
            erlang:erase(erlang:binary_to_atom(DevUID, latin1))
        end,
    {reply, Reply, State};
handle_call({start_qpusher, DevUID}, _From, State) ->
    QPPid = supervisor:start_child(hermes_q_pusher_sup, [DevUID]),
    erlang:put(erlang:binary_to_atom(DevUID, latin1), QPPid),
    {reply, QPPid, State};
handle_call({find_qpusher, DevUID}, _From, State) ->
    QPPid = erlang:get(erlang:binary_to_atom(DevUID, latin1)),
    {reply, QPPid, State};
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast({handle_socket, DevUID, PMPid, BinData}, State) ->
    % erlang:put(erlang:binary_to_atom(DevUID, latin1), ),
    handle_socket(DevUID, PMPid, BinData),
    {noreply, State};
handle_cast(start_acceptors, State) ->
    {ListenSocket, _} = State,
    [supervisor:start_child(hermes_accept_sup, [Id, ListenSocket]) || Id <- lists:seq(0, ?PROCNUM)],
    {noreply, State};
handle_cast(start_qpushers, State) ->
    % QPuList = erlang:get(),
    % [supervisor:start_child(hermes_q_pusher_sup, [DevUID, PMPid]) || {DevUID, PMPid} <- QPuList],
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, {ListenSocket, AMQPConnection}) ->
    gen_tcp:close(ListenSocket),
    amqp_connection:close(AMQPConnection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%----------------------------------------------------------------------------
%% server
server(Port) ->
    %% TODO: guard
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary,{active,false},{reuseaddr,true},{exit_on_close,true},{keepalive,false},{nodelay,true},{backlog,128}]),
    {ok, AMQPConnection} = amqp_connection:start(#amqp_params_direct{}, hermes_galileosky_server),
    %% -----------
    rabbit_log:info("Started Hermes Galileosky server at port ~p", [Port]), %% чокаво
    {ListenSocket, AMQPConnection}.
%%%----------------------------------------------------------------------------
%%% acceptor implementation
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
                        DevUID -> %% UID девайса детектед
                            gen_tcp:send(Socket, [<<2>>, Crc]), %% отправляем ответный CRC
                            gen_server:cast(hermes_worker, {handle_socket, DevUID, PMPid, BinData}), %% приступаем к водным процедурам
                            % handle_socket(DevUID, PMPid, BinData), %% приступаем к водным процедурам
                            rabbit_log:info("Hermes Galileosky server: acceptor #~p: client ~p, device UID=~p, pacman PID=~p, socket ~p", [Id, inet:peername(Socket), DevUID, PMPid, Socket]) %% чокаво
                    end;
                Any ->
                    rabbit_log:info("Hermes Galileosky server: acceptor #~p get ~p",[Id,Any])
            after 60000 ->
                rabbit_log:info("Hermes Galileosky server: acceptor #~p timeout: client ~p, pacman PID=~p, socket ~p~n", [Id, inet:peername(Socket), PMPid, Socket]), %% чокаво
                PMPid ! {abort, ok}
            end;
        {error, _} ->
            gen_tcp:close(Socket)
    end,
  accept(Id, ListenSocket).

%%%----------------------------------------------------------------------------
%%% Private helpers
handle_socket(DevUID, PMPid, BinData) -> %% ищем запущенный или рожаем новый обработчик данных от девайса.
    % case erlang:whereis(erlang:binary_to_atom(DevUID, latin1)) of
    % case erlang:get(erlang:binary_to_atom(DevUID, latin1)) of
    QPPid = case gen_server:call(hermes_worker, {find_qpusher, DevUID}) of
        undefined -> %% новый девайс
            Res = gen_server:call(hermes_worker, {start_qpusher, DevUID}),
            rabbit_log:info("Hermes Galileosky server: new qpusher for uid=~p pacman pid=~p", [DevUID, PMPid]), %% чокаво;
            Res;
        Res -> %% девайс переподключился на новый сокет
            rabbit_log:info("Hermes Galileosky server: found qpusher new pacman pid=~p for uid=~p", [PMPid, DevUID]), %% чокаво
            Res
    end,
    QPPid ! {new_socket, PMPid, BinData}.

packet_getid(<<>>) ->
    ok; %% no IMEI tag found
packet_getid(BinData) when erlang:is_binary(BinData) ->
    <<Tag:8, REst/binary>> = BinData,
    case Tag == 3 of
        false ->
            <<_:1/binary, Est/binary>> = REst,
            packet_getid(Est);
        true ->
            <<DevUID:120/bits, _/bits>> = REst,
            DevUID
    end.