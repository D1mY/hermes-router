%%%% Galileosky protocol default decoder
%%%% User's protocol over Galileosky protocol listener
-module(galileoskydec).

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

-record(state, {
    connection = undefined,
    channel = undefined,
    consumer_tag = undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    % process_flag(trap_exit, true), % bad practice?
    case decmap:unfold() of
        true ->
            self() ! configure;
        false ->
            rabbit_log:info("Hermes Galileosky broker: decmap unfold error during init")
    end,
    {ok, #state{}}.

%%%----------------------------------------------------------------------------
handle_call(get_connection, _From, State) ->
    {reply, State#state.connection, State};
handle_call({get_channel, DevUID}, _From, State) ->
    {reply, handle_pusher_channel(DevUID, State#state.connection), State};
handle_call(get_cfg_path, _From, State) ->
    {reply, cfg_path(), State};
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast({start_pusher, [DevUID, CfgData]}, State) ->
    start_pusher(DevUID, CfgData),
    {noreply, State};
handle_cast({stop_pusher, DevUID}, State) ->
    stop_pusher(PuName),
    {noreply, State};
handle_cast(restore_cfg, State) ->
    read_cfg_files(cfg_path()),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(
    {#'basic.deliver'{delivery_tag = DlvrTag}, Content},
    State = #state{channel = Channel}
) ->
    handle_content(Content),
    ack_msg(Channel, DlvrTag),
    {noreply, State};
handle_info(#'basic.cancel_ok'{}, State) ->
    {stop, normal, State};
handle_info(configure, _State) ->
    State = configure(),
    {noreply, State};
handle_info({'EXIT', _From, Reason}, State) ->
    terminate(Reason, State);
handle_info(_Info, State) ->
    {noreply, State}.

terminate(
    Reason,
    #state{
        connection = Connection,
        channel = Channel,
        consumer_tag = ConsTag
    }
) ->
    amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = ConsTag}),
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    rabbit_log:info("Hermes Galileosky broker terminated: ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%----------------------------------------------------------------------------
handle_content(Content) ->
    case Content#amqp_msg.props#'P_basic'.headers of
        [{<<"uid_psh">>, _, DevUID}] ->
            {value, CfgData, _} = parse_cfg(Content#amqp_msg.payload),
            handle_cfg_file(DevUID, CfgData),
            gen_server:cast(galileoskydec, {start_pusher, [DevUID, CfgData]});
        [{<<"uid_rmv">>, _, DevUID}] ->
            handle_cfg_file(DevUID, <<"uid_rmv">>),
            stop_pusher(erlang:binary_to_atom(<<"galileosky_pusher_", DevUID/binary>>));
        _ ->
            not_valid
    end.

start_pusher(DevUID, CfgData) ->
    PuName = erlang:binary_to_atom(<<"galileosky_pusher_", DevUID/binary>>),
    case
        supervisor:start_child(
            galileosky_pusher_sup,
            #{
                id => PuName,
                start => {galileosky_pusher, start, [DevUID]},
                restart => transient,
                shutdown => 10000,
                type => worker,
                modules => [galileosky_pusher]
            }
        )
    of
        {error, {already_started, _}} ->
            PuName ! {cfg, CfgData};
        {error, already_present} ->
            supervisor:restart_child(galileosky_pusher_sup, PuName);
        {error, What} ->
            rabbit_log:info("Hermes Galileosky broker: pusher for ~p start error ~p", [DevUID, What]);
        _ ->
            ok
    end.

stop_pusher(PuName) ->
    case supervisor:get_childspec(galileosky_pusher_sup, PuName) of
        {error, not_found} ->
            ok;
        _ ->
            supervisor:terminate_child(galileosky_pusher_sup, PuName), % more mercy
            supervisor:delete_child(galileosky_pusher_sup, PuName)
    end.

%%%-----------------------------------------------------------------------------
%%% helpers

configure() ->
    case rabbit:is_running() of
        false ->
            timer:sleep(1000),
            configure();
        true ->
            State = intercourse(),
            configure(State)
    end.

configure(State = #state{channel = Channel}) ->
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{
        exchange = <<"hermes.fanout">>,
        type = <<"fanout">>,
        passive = false,
        durable = true,
        auto_delete = false,
        internal = false
    }),
    #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{
        queue = <<"hermes">>, durable = true
    }),
    #'queue.bind_ok'{} = amqp_channel:call(Channel, #'queue.bind'{
        queue = <<"hermes">>, exchange = <<"hermes.fanout">>
    }),
    #'queue.declare_ok'{} = amqp_channel:call(Channel, #'queue.declare'{
        queue = <<"hermes_galileosky_broker_cfg">>, durable = true
    }),
    #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:call(
        Channel, #'basic.consume'{queue = <<"hermes_galileosky_broker_cfg">>}
    ),
    State#state{consumer_tag = ConsTag}.

intercourse() ->
    % TODO: garbage previous Connection (stored in ETS 'connection_created' table)
    {ok, Connection} = amqp_connection:start(#amqp_params_direct{}, <<"hermes_galileosky_broker">>),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    erlang:link(Connection),
    #state{connection = Connection, channel = Channel}.

handle_pusher_channel(DevUID, Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    % #'basic.consume_ok'{consumer_tag = ConsTag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = DevUID}, PuPid),
    Channel.

ack_msg(Channel, DlvrTag) ->
    case amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DlvrTag}) of
        ok ->
            ok;
        blocked ->
            timer:sleep(3000),
            ack_msg(Channel, DlvrTag);
        closing ->
            {ok, <<"Closing channel">>}
    end.

cfg_path() ->
    Path = filename:join([filename:basedir(user_config, []), "Hermes", erlang:node()]),
    case filelib:ensure_dir(Path ++ "/") of
        ok ->
            Path;
        {error, Reason} ->
            rabbit_log:info("Hermes Galileosky broker: cfg files location ~p error: ~p", [
                Path, Reason
            ]),
            error
    end.

%% find stored cfg files and start pushers
read_cfg_files(error) ->
    ok;
read_cfg_files(Path) ->
    filelib:fold_files(
        Path,
        "^hermes_galileosky_",
        true,
        fun(File, _) ->
            rabbit_log:info("Hermes Galileosky broker: found cfg ~p", [File]),
            UID = string:trim(File, leading, Path ++ "/hermes_galileosky_"),
            gen_server:cast(
                galileoskydec,
                {start_pusher, [erlang:list_to_binary(UID), []]}
            )
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
            file:write_file(File, erlang:term_to_binary(CfgData))
    end.

parse_cfg(<<>>) ->
    rabbit_log:info("Hermes Galileosky broker: default cfg request"),
    {value, [], []};
parse_cfg(Payload) ->
    CfgData = erlang:binary_to_list(Payload),
    case erl_scan:string(CfgData) of
        {ok, Tkns, _} ->
            case erl_parse:parse_exprs(Tkns) of
                {ok, ExprLst} ->
                    erl_eval:exprs(ExprLst, []);
                {error, ErrInf} ->
                    rabbit_log:info("Hermes Galileosky broker: parse expressions error: ~p", [
                        ErrInf
                    ]),
                    {value, [], []}
            end;
        {error, ErrInf, ErrLoc} ->
            rabbit_log:info("Hermes Galileosky broker: cfg read error: ~p~n location: ~p", [
                ErrInf, ErrLoc
            ]),
            {value, [], []}
    end.
