-module(hermes_uid_sniffer).
-export([init/3, do/1]).

%% Runs once when start sniffing;
%% no reinit after g_s_p_sup restarts.
init(Server, OffsetsTable, CfgData) ->
    DevUIDsSortedList = get_stream_resume_uids(OffsetsTable),
    start_pushers(DevUIDsSortedList, CfgData),
    Server ! {sniff_uids, DevUIDsSortedList, CfgData}.

do(CfgData) ->
    LC = get_active_pushers_uids(),
    LA =
        case erlang:whereis(hermes_worker) of
            undefined ->
                [];
            Pid ->
                gen_server:call(Pid, get_active_uids)
        end,
    LN = lists:subtract(LA, LC),
    LS = start_pushers(LN, CfgData),
    lists:umerge(LC, LS).

start_pushers([], _) ->
    [];
start_pushers(DevUIDsList, CfgData) ->
    lists:flatten([start_pusher(DevUID, CfgData) || DevUID <- DevUIDsList]).

start_pusher(DevUID, CfgData) ->
    PuName = erlang:binary_to_atom(<<"galileosky_pusher_", DevUID/binary>>),
    case
        supervisor:start_child(
            galileosky_pusher_sup,
            #{
                id => PuName,
                start => {galileosky_pusher, start, [DevUID, CfgData]},
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
    map_uid(LPN).

map_uid(L) ->
    map_uid(L, []).

map_uid([], Acc) ->
    lists:reverse(Acc);
map_uid([H|T], Acc) ->
    NewAcc = case H of
        <<"galileosky_pusher_", Rest/binary>> ->
            [Rest|Acc];
        _ ->
            Acc
    end,
    map_uid(T, NewAcc).