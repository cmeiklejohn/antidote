%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(antidote_db_wrapper).

-include("antidote.hrl").

-export([get_snapshot/3,
    put_snapshot/4,
    get_ops/4,
    put_op/4]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Gets the most suitable snapshot for Key that has been committed
%% before CommitTime. If its nothing is found, returns {error, not_found}
-spec get_snapshot(antidote_db:antidote_db(), key(),
    snapshot_time()) -> {ok, snapshot(), snapshot_time()} | {error, not_found}.
get_snapshot(AntidoteDB, Key, CommitTime) ->
    try
        antidote_db:fold(AntidoteDB,
            fun({K, V}, AccIn) ->
                {Key1, VC, SNAP} = binary_to_term(K),
                case (Key1 == Key) of %% check same key
                    true ->
                        %% check its a snapshot and its time is less than the one required
                        case (SNAP == snap) and
                            vectorclock:le(vectorclock:from_list(VC), CommitTime) of
                            true ->
                                Snapshot = binary_to_term(V),
                                throw({break, Snapshot, VC});
                            _ ->
                                AccIn
                        end;
                    false ->
                        throw({break})
                end
            end,
            [],
            [{first_key, term_to_binary({Key})}]),
        {error, not_found}
    catch
        {break, SNAP, VC} ->
            {ok, SNAP, VC};
        _ ->
            {error, not_found}
    end.

%% Saves the snapshot into AntidoteDB
-spec put_snapshot(antidote_db:antidote_db(), key(), snapshot_time(),
    snapshot()) -> ok | error.
put_snapshot(AntidoteDB, Key, SnapshotTime, Snapshot) ->
    SnapshotTimeList = vectorclock_to_list(SnapshotTime),
    antidote_db:put(AntidoteDB, {binary_to_atom(Key), SnapshotTimeList, snap}, Snapshot).

%% Returns a list of operations that have commit time in the range [VCFrom, VCTo]
-spec get_ops(antidote_db:antidote_db(), key(), vectorclock(), vectorclock()) -> list().
get_ops(AntidoteDB, Key, VCFrom, VCTo) ->
    VCFromDict = vectorclock_to_dict(VCFrom),
    VCToDict = vectorclock_to_dict(VCTo),
    try
        antidote_db:fold(AntidoteDB,
            fun({K, V}, AccIn) ->
                {Key1, VC1, OP} = binary_to_term(K),
                VC1Dict = vectorclock:from_list(VC1),
                case Key == Key1 of %% check same key
                    true ->
                        %% if its greater, continue
                        case vectorclock:gt(VC1Dict, VCToDict) of
                            true ->
                                AccIn;
                            false ->
                                %% check its an op and its commit time is in the required range
                                case not vectorclock:lt(VC1Dict, VCFromDict) of
                                    true ->
                                        case (OP == op) of
                                            true ->
                                                AccIn ++ [binary_to_term(V)];
                                            false ->
                                                AccIn
                                        end;
                                    false ->
                                        throw({break, AccIn})
                                end
                        end;
                    false ->
                        throw({break, AccIn})
                end
            end,
            [],
            [{first_key, term_to_binary({Key})}])
    catch
        {break, OPS} ->
            OPS;
        _ ->
            []
    end.

%% Saves the operation into AntidoteDB
-spec put_op(antidote_db:antidote_db(), key(), vectorclock(), operation()) -> ok | error.
put_op(AntidoteDB, Key, VC, Op) ->
    VCList = vectorclock_to_list(VC),
    antidote_db:put(AntidoteDB, {binary_to_atom(Key), VCList, op}, Op).

vectorclock_to_dict(VC) ->
    case is_list(VC) of
        true -> vectorclock:from_list(VC);
        false -> VC
    end.

vectorclock_to_list(VC) ->
    case is_list(VC) of
        true -> VC;
        false -> vectorclock:to_list(VC)
    end.

%% Workaround for basho bench
%% TODO find a better solution to this
binary_to_atom(Key) ->
    case is_binary(Key) of
        true -> list_to_atom(integer_to_list(binary_to_integer(Key)));
        false -> Key
    end.

-ifdef(TEST).

get_snapshot_not_found_test() ->
    eleveldb:destroy("get_snapshot_not_found_test", []),
    {ok, AntidoteDB} = antidote_db:new("get_snapshot_not_found_test"),

    Key = key,
    Key1 = key1,
    Key2 = key2,
    %% No snapshot in the DB
    NotFound = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 0}, {remote, 0}])),
    ?assertEqual({error, not_found}, NotFound),

    %% Put 10 snapshots for Key and check there is no snapshot with time 0 in both DCs
    put_n_snapshots(AntidoteDB, Key, 10),
    NotFound1 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 0}, {remote, 0}])),
    ?assertEqual({error, not_found}, NotFound1),

    %% Look for a snapshot for Key1
    S1 = get_snapshot(AntidoteDB, Key1, vectorclock:from_list([{local, 5}, {remote, 4}])),
    ?assertEqual({error, not_found}, S1),

    %% Put snapshots for Key2 and look for a snapshot for Key1
    put_n_snapshots(AntidoteDB, Key2, 10),
    S2 = get_snapshot(AntidoteDB, Key1, vectorclock:from_list([{local, 5}, {remote, 4}])),
    ?assertEqual({error, not_found}, S2),

    antidote_db:close_and_destroy(AntidoteDB, "get_snapshot_not_found_test").

get_snapshot_matching_vc_test() ->
    eleveldb:destroy("get_snapshot_matching_vc_test", []),
    {ok, AntidoteDB} = antidote_db:new("get_snapshot_matching_vc_test"),

    Key = key,
    put_n_snapshots(AntidoteDB, Key, 10),

    %% get some of the snapshots inserted (matches VC)
    S1 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 1}, {remote, 1}])),
    S2 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 4}, {remote, 4}])),
    S3 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 8}, {remote, 8}])),
    ?assertEqual({ok, 1, [{local, 1}, {remote, 1}]}, S1),
    ?assertEqual({ok, 4, [{local, 4}, {remote, 4}]}, S2),
    ?assertEqual({ok, 8, [{local, 8}, {remote, 8}]}, S3),

    antidote_db:close_and_destroy(AntidoteDB, "get_snapshot_matching_vc_test").


get_snapshot_not_matching_vc_test() ->
    eleveldb:destroy("get_snapshot_not_matching_vc_test", []),
    {ok, AntidoteDB} = antidote_db:new("get_snapshot_not_matching_vc_test"),

    Key = key,
    put_n_snapshots(AntidoteDB, Key, 10),

    %% get snapshots with different times in their DCs
    S4 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 1}, {remote, 0}])),
    S5 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 5}, {remote, 4}])),
    S6 = get_snapshot(AntidoteDB, Key, vectorclock:from_list([{local, 8}, {remote, 9}])),
    ?assertEqual({error, not_found}, S4),
    ?assertEqual({ok, 4, [{local, 4}, {remote, 4}]}, S5),
    ?assertEqual({ok, 8, [{local, 8}, {remote, 8}]}, S6),

    antidote_db:close_and_destroy(AntidoteDB, "get_snapshot_not_matching_vc_test").

get_operations_empty_result_test() ->
    eleveldb:destroy("get_operations_not_found_test", []),
    {ok, AntidoteDB} = antidote_db:new("get_operations_not_found_test"),
    Key = key,
    Key1 = key1,
    %% Nothing in the DB yet return empty list
    O1 = get_ops(AntidoteDB, Key, [{local, 2}, {remote, 2}], [{local, 8}, {remote, 9}]),
    ?assertEqual([], O1),

    put_n_operations(AntidoteDB, Key, 10),
    %% Getting something out of range returns an empty list
    O2 = get_ops(AntidoteDB, Key, [{local, 123}, {remote, 100}], [{local, 200}, {remote, 124}]),
    ?assertEqual([], O2),

    %% Getting a key not present, returns an empty list
    O3 = get_ops(AntidoteDB, Key1, [{local, 2}, {remote, 2}], [{local, 4}, {remote, 5}]),
    ?assertEqual([], O3),

    %% Searching for the same range returns an empty list
    O4 = get_ops(AntidoteDB, Key1, [{local, 2}, {remote, 2}], [{local, 2}, {remote, 2}]),
    ?assertEqual([], O4),

    antidote_db:close_and_destroy(AntidoteDB, "get_operations_not_found_test").


get_operations_non_empty_test() ->
    eleveldb:destroy("get_operations_non_empty_test", []),
    {ok, AntidoteDB} = antidote_db:new("get_operations_non_empty_test"),

    %% Fill the DB with values
    Key = key,
    Key1 = key1,
    Key2 = key2,
    put_n_operations(AntidoteDB, Key, 100),
    put_n_operations(AntidoteDB, Key1, 10),
    put_n_operations(AntidoteDB, Key2, 25),

    %% concurrent operations are present in the result
    O1 = get_ops(AntidoteDB, Key1, [{local, 2}, {remote, 2}], [{local, 8}, {remote, 9}]),
    O2 = get_ops(AntidoteDB, Key1, [{local, 4}, {remote, 5}], [{local, 7}, {remote, 7}]),
    ?assertEqual([9,8,7,6,5,4,3,2], O1),
    ?assertEqual([7,6,5,4], O2),

    antidote_db:close_and_destroy(AntidoteDB, "get_operations_non_empty_test").

operations_and_snapshots_mixed_test() ->
    eleveldb:destroy("operations_and_snapshots_mixed_test", []),
    {ok, AntidoteDB} = antidote_db:new("operations_and_snapshots_mixed_test"),

    Key = key,
    Key1 = key1,
    Key2 = key2,
    VCTo = [{local, 7}, {remote, 8}],
    put_n_operations(AntidoteDB, Key, 10),
    put_n_operations(AntidoteDB, Key1, 20),
    put_snapshot(AntidoteDB, Key1, [{local, 2}, {remote, 3}], 5),
    put_n_operations(AntidoteDB, Key2, 8),

    %% We want all ops for Key1 that are between the snapshot and
    %% [{local, 7}, {remote, 8}]. First get the snapshot, then OPS.
    {ok, Value, VCFrom} = get_snapshot(AntidoteDB, Key1, vectorclock:from_list(VCTo)),
    ?assertEqual({ok, 5, [{local, 2}, {remote, 3}]}, {ok, Value, VCFrom}),

    O1 = get_ops(AntidoteDB, Key1, VCFrom, VCTo),
    ?assertEqual([8, 7, 6, 5, 4, 3, 2], O1),

    antidote_db:close_and_destroy(AntidoteDB, "operations_and_snapshots_mixed_test").

put_n_snapshots(_AntidoteDB, _Key, 0) ->
    ok;
put_n_snapshots(AntidoteDB, Key, N) ->
    put_snapshot(AntidoteDB, Key, [{local, N}, {remote, N}], N),
    put_n_snapshots(AntidoteDB, Key, N - 1).

put_n_operations(_AntidoteDB, _Key, 0) ->
    ok;
put_n_operations(AntidoteDB, Key, N) ->
    put_op(AntidoteDB, Key, [{local, N}, {remote, N}], N),
    put_n_operations(AntidoteDB, Key, N - 1).

-endif.
