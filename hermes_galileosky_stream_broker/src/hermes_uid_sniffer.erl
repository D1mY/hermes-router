-module(hermes_uid_sniffer).
-export([start_link/1, init/1]).

start_link(OffsetsTable) ->
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
    CfgData = ets:tab2list(hermes_sniffer_cfg),
    lists:flatten([start_pusher(DevUID, CfgData) || DevUID <- DevUIDsList]).

start_pusher(DevUID, CfgData) ->
    gen_server:cast(galileoskydec, {start_pusher, [DevUID, CfgData]}).

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
