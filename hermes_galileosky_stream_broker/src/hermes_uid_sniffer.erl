-module(hermes_uid_sniffer).
-export([start/1, init/1]).

start(OffsetsTable) ->
    {ok, erlang:spawn_link(?MODULE, init, [OffsetsTable])}.

init(OffsetsTable) ->
    DevUIDsSortedList = get_stream_resume_uids(OffsetsTable),
    % CfgData = ets:tab2list(hermes_sniffer_cfg),
    start_pushers(DevUIDsSortedList),
    loop().

loop() ->
        receive
            sniff ->
                do(),
                erlang:send_after(5000, self(), sniff),
                loop();
            stop ->
                ok;
            _ ->
                loop()
        end.

do() ->
    LC = get_active_pushers_uids(),
    LA =
        case erlang:whereis(hermes_worker) of
            undefined ->
                [];
            Pid ->
                gen_server:call(Pid, get_active_uids)
        end,
    LN = lists:subtract(LA, LC),
    start_pushers(LN).
% LS = start_pushers(LN, CfgData),
% lists:umerge(LC, LS),

start_pushers([]) ->
    [];
start_pushers(DevUIDsList) ->
    lists:flatten([start_pusher(DevUID) || DevUID <- DevUIDsList]).

start_pusher(DevUID) ->
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
        {ok, _} ->
            DevUID;
        {ok, _, _} ->
            DevUID;
        {error, already_present} ->
            supervisor:restart_child(galileosky_pusher_sup, PuName),
            DevUID;
        {error, {already_started, _}} ->
            DevUID;
        {error, What} ->
            rabbit_log:info(
                "Hermes Galileosky stream broker: sniffer's pusher for ~p start error: ~p", [
                    DevUID, What
                ]
            ),
            []
    end.

get_stream_resume_uids(OffsetsTable) ->
    OffsetsList = ets:tab2list(OffsetsTable),
    DevUIDsDraftList = proplists:delete(saved, OffsetsList),
    DevUIDsList = proplists:get_keys(DevUIDsDraftList),
    lists:usort(DevUIDsList).

get_active_pushers_uids() ->
    LSP = supervisor:which_children(galileosky_pusher_sup),
    LPN = proplists:get_keys(LSP),
    map_uid(LPN, []).

map_uid([], Acc) ->
    lists:reverse(Acc);
map_uid([H | T], Acc) ->
    NewAcc =
        case H of
            <<"galileosky_pusher_", Rest/binary>> ->
                [Rest | Acc];
            _ ->
                Acc
        end,
    map_uid(T, NewAcc).
