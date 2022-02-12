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
		accept/2	
		]).

-define(PROCNUM, 9). %% Кол-во ожидающих accept-ов минус один

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    server(application:get_env(hermes_galileosky, tcp_port, 60521)). %% запускаем сервер при старте плагина на порту из конфига (или дефолт: 60521)
    % gen_server:cast({global,?MODULE}, {server, Port}),
    % rabbit_log:info("Ya sdelyallll ;)",[]),
    % {ok, {?MODULE, Port}}.

%----------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

% handle_cast({server, Port}, State)->
%     {ok, ListenSocket} = gen_tcp:listen(Port, [binary,{active,false},{reuseaddr,true},{exit_on_close,true},{keepalive,false},{nodelay,true},{backlog,128}]),
%     rabbit_log:info("Started Hermes-Galileosky server at port ~p~n", [Port]),
%     NewState = [erlang:spawn_link(?MODULE, accept, [Id, ListenSocket]) || Id <- lists:seq(0, ?PROCNUM)],
%     rabbit_log:info("Hermes acceptors list ~p for port ~p",[NewState,Port]),
%     timer:sleep(infinity),
%     rabbit_log:info("No sleep? WTF!?",[]),
%     {noreply,{State, NewState}};
handle_cast(_, State) ->
    {noreply,State}.

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
  rabbit_log:info("Started Hermes-Galileosky server at port ~p", [Port]), %% чокаво
  NewState = [erlang:spawn_link(?MODULE, accept, [Id, ListenSocket]) || Id <- lists:seq(0, ?PROCNUM)],
  rabbit_log:info("Hermes-Galileosky~nacceptors list ~p for port ~p",[NewState, Port]), %% чокаво
  timer:sleep(infinity).

accept(Id, ListenSocket) -> %% прием TCP соединения от устройства
  rabbit_log:info("Hermes-Galileosky~nacceptor #~p: wait for client", [Id]), %% чокаво
  %% TODO: guard
  {ok, Socket} = gen_tcp:accept(ListenSocket),
  %% -----------
  rabbit_log:info("Hermes-Galileosky~nacceptor #~p: client connected on socket ~p", [Id, Socket]), %% чокаво
  case gen_tcp:controlling_process(Socket, PMPid = erlang:spawn(galileo_pacman, packet_manager, [Socket, 61000])) of %% рожаем pacman-а и вешаем ему сокет
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
              rabbit_log:info("Hermes-Galileosky~nacceptor #~p: client ~p, device UID=~p, pacman PID=~p, socket ~p", [Id, inet:peername(Socket), Dev_UID, PMPid, Socket]) %% чокаво
          end;
        Any ->
          rabbit_log:info("Hermes-Galileosky~nacceptor #~p get ~p",[Id,Any])
      after 60000 ->
        rabbit_log:info("Hermes-Galileosky~nacceptor #~p timeout: client ~p, pacman PID=~p, socket ~p~n", [Id, inet:peername(Socket), PMPid, Socket]), %% чокаво
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
      rabbit_log:info("Hermes-Galileosky~nnew qpusher for uid=~p pacman pid=~p", [Dev_UID, PMPid]); %% чокаво;
    QPPid -> %% девайс переподключился на новый сокет
      QPPid ! {new_socket, PMPid, BinData},
      rabbit_log:info("Hermes-Galileosky~nfound qpusher ~p: new pacman pid=~p for uid=~p", [QPPid, PMPid, Dev_UID]) %% чокаво
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