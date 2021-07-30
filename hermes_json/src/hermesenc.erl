%%%% Galileosky protocol default decoder
%%%% User's protocol over Galileosky protocol listener
-module (hermesenc).

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
        rmq_connect/0
		]).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    rmq_connect().

%%%----------------------------------------------
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
%%%----------------------------------------------

rmq_connect() ->
  %% create RabbirMQ connection for self() and spawn_link() prcss
  Connection = intercourse(<<"hermes_json">>, amqp_connection:start(#amqp_params_direct{},<<"hermes_json">>)),
  %% subscribe to cfg queue
  Channel = intercourse(Connection, amqp_connection:open_channel(Connection)),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes_json_cfg">>, durable = true}),
  #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{queue = <<"hermes">>, durable = true}),
  #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = <<"hermes_json_cfg">>}, self()),
  ok = persistent_term:put({'hermes_json','rabbitmq_connection'},Connection),
  read_cfg_file(cfg_path()),
  pusher_schedule(16),
  %% bgn listen cfg queue
  loop(Channel),
  %% ending
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
  rabbit_log:info("Hermes JSON close channel: ~p~n", [amqp_channel:close(Channel)]),
  rabbit_log:info("Hermes JSON close connection: ~p~n", [amqp_connection:close(Connection)]),
  persistent_term:erase({'hermes_json','rabbitmq_con_ch'}),
  rabbit_log:info("Hermes JSON ended",[]).

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
      handle_cfg(DevUID, CfgData);
    _ -> 'not_valid'
  end.

handle_cfg(DevUID,[]) ->
  persistent_term:erase({'hermes_json', DevUID});
handle_cfg(DevUID,CfgData) ->
  persistent_term:put({'hermes_json', DevUID}, CfgData).

%%%TODO: start/stop pushers due queue load
pusher_schedule(0) ->
  ok;
pusher_schedule(Num) ->
  erlang:spawn_link(json_pusher,start,[<<"hermes">>]),
  pusher_schedule(Num-1).

%%%----------------------------------------------------------------------------
%%% helpers
cfg_path() ->
  Path = filename:join([filename:basedir(user_config,[]),"Hermes",erlang:node()]),
  case filelib:ensure_dir(Path ++ "/") of
    ok ->
      Path;
    {error,Reason} ->
      rabbit_log:info("Hermes cfg files location ~p error: ~p~n",[Path,Reason]),
      'error'
  end.

read_cfg_file('error') ->
  ok;
read_cfg_file(Path) ->
  filelib:fold_files(
    Path,
    "^hermes_json_",
    true,
    fun(File,_) ->
      case file:read_file(File) of
        {ok, T} ->
          DevUID = string:trim(File, leading, Path ++ "/hermes_json_"),
          handle_cfg(erlang:list_to_binary(DevUID),erlang:binary_to_term(T));
        {error, Reason} ->
          rabbit_log:info("Hermes JSON: cfg ~p load error: ~p~n",[File,Reason])
      end
    end,
    []
  ).

handle_cfg_file(DevUID, CfgData) ->
  File = cfg_path() ++ "/hermes_json_" ++ erlang:binary_to_list(DevUID),
  case CfgData of
    [] ->
      % TODO: response result
      file:delete(File);
    _ ->
      % TODO: response result
      file:write_file(File,erlang:term_to_binary(CfgData))
  end.

intercourse(_, {ok, Res}) ->
  Res;
intercourse(X, {error, _}) ->
  timer:sleep(3000),
  case erlang:is_bitstring(X) of
    true -> rmq_connect();
    false -> intercourse(X, amqp_connection:open_channel(X))
  end.

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

parse_cfg(Payload) ->
  CfgData = erlang:binary_to_list(Payload),
  case erl_scan:string(CfgData) of
    {ok,Tkns,_} ->
      case erl_parse:parse_exprs(Tkns) of
        {ok,ExprLst} ->
          erl_eval:exprs(ExprLst, []);
        {error,ErrInf} ->
          rabbit_log:info("Hermes parse expressions error: ~p~n",[ErrInf]),
          {value,[],[]}
      end;
    {error,ErrInf,ErrLoc} ->
      rabbit_log:info("Hermes read cfg error: ~p~n location: ~p~n",[ErrInf,ErrLoc]),
      {value,[],[]}
  end.