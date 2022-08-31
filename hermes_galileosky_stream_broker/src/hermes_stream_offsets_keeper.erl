%%% Module provides functions to deal with stream offsets.
%%% Uses {saved, 0|1} element as save decision flag.

-module(hermes_stream_offsets_keeper).

-define(OFFSETETS, hermes_galileosky_stream_offsets).
-define(SAVEINTERVAL, 180000).

-export([
    init/0,
    get_offset/1,
    save_offset/2,
    save_offsets/1
]).

init() ->
    {ok, OffsetsDETSName} = dets:open_file(
        erlang:atom_to_list(erlang:node()) ++ "_hermes_galileosky_stream_offsets",
        []
    ),
    ets:new(?OFFSETETS, [
        named_table, public, {write_concurrency, true}, {read_concurrency, true}
    ]),
    ets:from_dets(?OFFSETETS, OffsetsDETSName),
    timer:apply_interval(?SAVEINTERVAL, ?MODULE, save_offsets, [OffsetsDETSName]).

get_offset(Q) ->
    case ets:lookup(?OFFSETETS, Q) of
        [{_, Offset}] ->
            Offset + 1;
        [] ->
            0
    end.

save_offset(Id, Offset) ->
    ets:insert(?OFFSETETS, [{Id, Offset}, {saved, 0}]).

save_offsets(OffsetsDETSName) ->
    case ets:lookup(?OFFSETETS, saved) of
        [{saved, 1}] ->
            ok;
        _ ->
            ets:insert(?OFFSETETS, {saved, 1}),
            ets:to_dets(?OFFSETETS, OffsetsDETSName)
    end.
