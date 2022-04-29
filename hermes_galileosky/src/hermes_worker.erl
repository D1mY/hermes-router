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
    % server/1,
    accept/2
]).

%% Кол-во ожидающих accept-ов минус один
-define(PROCNUM, 9).
-define(ETS_TABLE, hermes_galileosky_server).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    %% отложенный старт
    self() ! start_server,
    {ok, {undefined, undefined}}.

%%%----------------------------------------------------------------------------
handle_call(init_ets_table, _From, State) ->
    ets:delete_all_objects(?ETS_TABLE),
    {reply, ok, State};
handle_call({init_qpusher, DevUID}, _From, State) ->
    PMPid =
        case ets:lookup(?ETS_TABLE, DevUID) of
            [{_, Res}] -> Res;
            _ -> undefined
        end,
    {_, AMQPConnection} = State,
    {reply, {PMPid, AMQPConnection}, State};
handle_call({stop_pacman, DevUID}, _From, State) ->
    case ets:take(?ETS_TABLE, DevUID) of
        [{_, PMPid}] -> PMPid ! {abort, ok};
        _ -> ok
    end,
    {reply, ok, State};
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast({handle_socket, DevUID, PMPid, BinData}, State) ->
    ets:update_element(?ETS_TABLE, DevUID, {3, PMPid}),
    case handle_socket(DevUID) of
        undefined ->
            PMPid ! {abort, ok};
        QPPid ->
            QPPid ! {new_socket, PMPid, BinData}
    end,
    {noreply, State};
handle_cast(start_acceptors, State) ->
    {ListenSocket, _} = State,
    [supervisor:start_child(hermes_accept_sup, [Id, ListenSocket]) || Id <- lists:seq(0, ?PROCNUM)],
    {noreply, State};
handle_cast(start_qpushers, State) ->
    PacManList = ets:tab2list(?ETS_TABLE),
    [supervisor:start_child(hermes_q_pusher_sup, [DevUID]) || {DevUID, _, _} <- PacManList],
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(start_server, _State) ->
    %% создаём ETS таблицу для {DevUID :: bitstring(), PMPid :: pid()}
    ets:new(?ETS_TABLE, [named_table]),
    %% запускаем сервер на порту из конфига (или дефолт: 60521)
    NewState = server(application:get_env(hermes_galileosky, tcp_port, 60521)),
    self() ! started_server,
    {noreply, NewState};
handle_info(started_server, State) ->
    erlang:register(?MODULE, self()),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, {ListenSocket, AMQPConnection}) ->
    case ListenSocket of
        undefined -> ok;
        _ -> gen_tcp:close(ListenSocket)
    end,
    case AMQPConnection of
        undefined -> ok;
        _ -> amqp_connection:close(AMQPConnection)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------------
%% server
server(Port) ->
    % timer:sleep(10000),
    wait_rabbit_start(),
    %% TODO: guard
    {ok, AMQPConnection} = amqp_connection:start(#amqp_params_direct{}, <<"hermes_galileosky_server">>),
    {ok,_C} = amqp_connection:open_channel(AMQPConnection),
    erlang:link(AMQPConnection),
    {ok, ListenSocket} = gen_tcp:listen(Port, [
        binary,
        {active, false},
        {reuseaddr, true},
        {exit_on_close, true},
        {keepalive, false},
        {nodelay, true},
        {backlog, 128}
    ]),
    %% -----------
    rabbit_log:info("Started Hermes Galileosky server at port ~p", [Port]),
    {ListenSocket, AMQPConnection}.

%%%----------------------------------------------------------------------------
%%% acceptor implementation

%% прием TCP соединения от устройства
accept(Id, ListenSocket) ->
    rabbit_log:info("Hermes Galileosky server: acceptor #~p wait for client", [Id]),
    %% TODO: guard
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    %% -----------
    rabbit_log:info("Hermes Galileosky server: acceptor #~p: client connected on socket ~p", [
        Id, Socket
    ]),
    %% TODO: guard
    {ok, PMPid} = supervisor:start_child(galileo_pacman_sup, [Socket, 61000]),
    %% -----------
    case gen_tcp:controlling_process(Socket, PMPid) of
        ok ->
            %% у родившегося pacman-а запрашиваем пакет от девайса
            PMPid ! {get, self()},
            receive
                %% принят ответ от рожденного pacman-а
                {p_m, PMPid, Socket, Crc, BinData} ->
                    case packet_getid(BinData) of
                        %% UID девайса нот детектед
                        ok ->
                            PMPid ! {abort, ok};
                        %% UID девайса детектед
                        DevUID ->
                            %% отправляем ответный CRC
                            gen_tcp:send(Socket, [<<2>>, Crc]),
                            %% приступаем к водным процедурам
                            gen_server:cast(hermes_worker, {handle_socket, DevUID, PMPid, BinData}),
                            rabbit_log:info(
                                "Hermes Galileosky server: acceptor #~p: client ~p, device UID=~p, pacman PID=~p, socket ~p",
                                [Id, inet:peername(Socket), DevUID, PMPid, Socket]
                            )
                    end;
                Any ->
                    PMPid ! {abort, ok},
                    rabbit_log:info("Hermes Galileosky server: acceptor #~p get ~p", [Id, Any])
                %% таймаут ожидания ответа от устройства
            after 60000 ->
                rabbit_log:info(
                    "Hermes Galileosky server: acceptor #~p timeout: client ~p, pacman PID=~p, socket ~p~n",
                    [Id, inet:peername(Socket), PMPid, Socket]
                ),
                PMPid ! {abort, ok}
            end;
        {error, _} ->
            gen_tcp:close(Socket)
    end,
    accept(Id, ListenSocket).

%%%----------------------------------------------------------------------------
%%% Private helpers

%% рожаем новый или ищем запущенный обработчик данных от девайса.
%% REDO: s_o_f_o sup acts other way
handle_socket(DevUID) ->
    case ets:lookup_element(hermes_galileosky_server, DevUID, 2) of
        QPPid ->
            supervisor:start_child(hermes_q_pusher_sup, [DevUID]),
    ok.
    % case supervisor:start_child(hermes_q_pusher_sup, [DevUID]) of
    %     %% новый девайс
    %     {ok, Child} ->
    %         Child;
    %     {ok, Child, _Info} ->
    %         Child;
    %     %% девайс переподключился на новый сокет
    %     {error, {already_started, Child}} ->
    %         Child;
    %     %% неведома херня
    %     _ ->
    %         undefined
    % end.

packet_getid(<<>>) ->
    %% no IMEI tag found
    ok;
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

wait_rabbit_start() ->
    case rabbit:is_running() of
        false ->
            timer:sleep(1000),
            wait_rabbit_start();
        true ->
            ok
    end.
