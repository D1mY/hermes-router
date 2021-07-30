%%%% Galileosky protocol default decoder
%%%% User's protocol over Galileosky protocol listener
-module (galileoskydec).

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

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    configure().

%%%----------------------------------------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(_, State) ->
    {noreply,State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, {?MODULE, Port}) ->
    gen_tcp:close(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%----------------------------------------------------------------------------

configure() ->
  configure(decmap:unfold()).
configure(true) ->
  rmq_connect();
configure(false) ->
  rabbit_log:info("Hermes Galileosky decmap unfold error~n",[]).

rmq_connect() ->
  %% create RabbirMQ connection for self() and spawn_link() prcss
  Connection = intercourse(<<"hermes_galileosky_broker">>, amqp_connection:start(#amqp_params_direct{},<<"hermes_galileosky_broker">>)),
  ok = persistent_term:put({hermes_galileosky_broker,rabbitmq_connection},Connection),
  %% subscribe to cfg queue
  Channel = intercourse(Connection, amqp_connection:open_channel(Connection)),
  #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"hermes.fanout">>, type = <<"fanout">>, passive = false, durable = true, auto_delete = false, internal = false}),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes">>, durable = true}),
  #'queue.bind_ok'{} = amqp_channel:call(Channel,#'queue.bind'{queue = <<"hermes">>, exchange = <<"hermes.fanout">>}),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes_galileosky_broker_cfg">>, durable = true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = <<"hermes_galileosky_broker_cfg">>}, self()),
  %% loading stored cfg
  read_cfg_file(cfg_path()),
  %% bgn listen cfg queue
  loop(Channel),
  %% ending
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
  rabbit_log:info("Hermes Galileosky broker close channel: ~p~n", [amqp_channel:close(Channel)]),
  rabbit_log:info("Hermes Galileosky broker close connection: ~p~n", [amqp_connection:close(Connection)]),
  persistent_term:erase({hermes_galileosky_broker,rabbitmq_connection}),
  rabbit_log:info("Hermes Galileosky broker ended",[]).

%%% cfg queue loop
loop(Channel) ->
  receive
    {#'basic.deliver'{delivery_tag = DlvrTag}, Content} ->
      handle_content(Content),
      ack_msg(Channel, DlvrTag);
    #'basic.cancel_ok'{} ->
      {ok, <<"Cancel">>};
    _ -> loop(Channel)
  end.

handle_content(Content) ->
  case Content#amqp_msg.props#'P_basic'.headers of
    [{<<"uid_psh">>,_,DevUID}] ->
      {value,CfgData,_} = parse_cfg(Content#amqp_msg.payload),
      handle_cfg_file(DevUID, CfgData),
      start_pusher(DevUID, CfgData);
    [{<<"uid_rmv">>,_,DevUID}] ->
      handle_cfg_file(DevUID, <<"uid_rmv">>),
      stop_pusher(erlang:binary_to_atom(<<"galileosky_pusher_", DevUID/binary>>));
    _ -> 'not_valid'
  end.

start_pusher(Dev, CfgDev) ->
  PuName = erlang:binary_to_atom(<<"galileosky_pusher_", Dev/binary>>),
  case lists:member(PuName,erlang:registered()) of
    false ->
      erlang:register(PuName,erlang:spawn_link(galileosky_pusher,start,[Dev]));
    true ->
      ok
    end,
  PuName ! {cfg,CfgDev}.

stop_pusher(Dev) ->
  case lists:member(Dev,erlang:registered()) of
    false ->
      ok;
    true ->
      Dev ! {stop,self()}
  end.

%%%-----------------------------------------------------------------------------
%%% helpers
ack_msg(Channel, DlvrTag) ->
  case amqp_channel:call(Channel,#'basic.ack'{delivery_tag = DlvrTag}) of
    ok ->
      loop(Channel);
    blocked ->
      timer:sleep(3000),
      ack_msg(Channel, DlvrTag);
    closing ->
      {ok, <<"Closing channel">>}
  end.

cfg_path() ->
  Path = filename:join([filename:basedir(user_config,[]),"Hermes",erlang:node()]),
  case filelib:ensure_dir(Path ++ "/") of
    ok ->
      Path;
    {error,Reason} ->
      rabbit_log:info("Hermes cfg files location ~p error: ~p~n",[Path,Reason]),
      error
  end.

read_cfg_file(error) ->
  ok;
read_cfg_file(Path) ->
  filelib:fold_files(
    Path,
    "^hermes_galileosky_",
    true,
    fun(File,_) ->
      case file:read_file(File) of
        {ok, T} ->
          rabbit_log:info("Hermes Galileosky broker: found cfg ~p~n",[File]),
          UID = string:trim(File, leading, Path ++ "/hermes_galileosky_"),
          start_pusher(erlang:list_to_binary(UID),erlang:binary_to_term(T));
        {error, Reason} ->
          rabbit_log:info("Hermes Galileosky broker: cfg ~p load error: ~p~n",[File,Reason])
      end
    end,
    []
  ).

handle_cfg_file(DevUID, CfgData) ->
  File = cfg_path() ++ "/hermes_galileosky_" ++ erlang:binary_to_list(DevUID),
  case CfgData of
    <<"uid_rmv">> ->
      % TODO: response result
      file:delete(File);
    _ ->
      % TODO: response result
      file:write_file(File,erlang:term_to_binary(CfgData))
  end.

intercourse(_, {ok, Res}) -> Res;
intercourse(X, {error, _}) ->
  timer:sleep(3000),
  case erlang:is_bitstring(X) of
    true -> rmq_connect();
    false -> intercourse(X, amqp_connection:open_channel(X))
  end.

parse_cfg(<<>>) ->
  rabbit_log:info("Hermes Galileosky broker: default cfg request~n",[]),
  {value,[],[]};
parse_cfg(Payload) ->
  CfgData = erlang:binary_to_list(Payload),
  case erl_scan:string(CfgData) of
    {ok,Tkns,_} ->
      case erl_parse:parse_exprs(Tkns) of
        {ok,ExprLst} ->
          erl_eval:exprs(ExprLst, []);
        {error,ErrInf} ->
          rabbit_log:info("Hermes Galileosky broker: parse expressions error: ~p~n",[ErrInf]),
          {value,[],[]}
      end;
    {error,ErrInf,ErrLoc} ->
      rabbit_log:info("Hermes Galileosky broker: cfg read error: ~p~n location: ~p~n",[ErrInf,ErrLoc]),
      {value,[],[]}
  end.