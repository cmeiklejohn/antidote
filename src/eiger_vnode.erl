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
-module(eiger_vnode).
-behaviour(riak_core_vnode).

-include("antidote.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(EIGER_MASTER, eiger_vnode_master).

-export([start_vnode/1,
         read_key/4,
         read_key_time/5,
         prepare/4,
         prepare_replicated/3,
         commit/6,
         commit_replicated/3,
         coordinate_tx/4,
         check_deps/2,
         get_clock/1,
         update_clock/2,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-ignore_xref([start_vnode/1]).

-record(state, {partition,
                min_pendings=dict:new() :: dict(),
                buffered_reads=dict:new() :: dict(),
                pending=dict:new() :: dict(),
                clock=0 :: integer()}).

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).


check_deps(Node, Deps) ->
    riak_core_vnode_master:command(Node,
                                   {check_deps, Deps},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).

read_key(Node, Key, Type, TxId) ->
    riak_core_vnode_master:command(Node,
                                   {read_key, Key, Type, TxId},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).

read_key_time(Node, Key, Type, TxId, Clock) ->
    riak_core_vnode_master:command(Node,
                                   {read_key_time, Key, Type, TxId, Clock},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).

prepare(Node, Transaction, Clock, Keys) ->
    riak_core_vnode_master:command(Node,
                                   {prepare, Transaction, Clock, Keys},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).

prepare_replicated(Node, TxId, Keys) ->
    riak_core_vnode_master:command(Node,
                                   {prepare_replicated, TxId, Keys},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).
commit(Node, Transaction, Updates, Deps, Clock, TotalOps) ->
    riak_core_vnode_master:command(Node,
                                   {commit, Transaction, Updates, Deps, Clock, TotalOps},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).

commit_replicated(Node, Transaction, Updates) ->
    riak_core_vnode_master:command(Node,
                                   {commit_replicated, Transaction, Updates},
                                   {fsm, undefined, self()},
                                   ?EIGER_MASTER).

coordinate_tx(Node, Updates, Deps, Debug) ->
    riak_core_vnode_master:sync_command(Node,
                                        {coordinate_tx, Updates, Deps, Debug},
                                        ?EIGER_MASTER,
                                        infinity).

get_clock(Node) ->
    riak_core_vnode_master:sync_command(Node,
                                        get_clock,
                                        ?EIGER_MASTER,
                                        infinity).

update_clock(Node, Clock) ->
    riak_core_vnode_master:sync_command(Node,
                                        {update_clock, Clock},
                                        ?EIGER_MASTER,
                                        infinity).
%% @doc Initializes all data structures that vnode needs to track information
%%      the transactions it participates on.
init([Partition]) ->
    {ok, #state{partition=Partition}}.

handle_command({check_deps, _Deps}, _Sender, State0) ->
    {reply, deps_checked, State0};

%% @doc starts a read_fsm to handle a read operation.
handle_command({read_key, Key, Type, TxId}, _Sender,
               #state{clock=Clock, min_pendings=MinPendings}=State) ->
    case dict:find(Key, MinPendings) of
        {ok, _Min} ->
            {reply, {Key, empty, empty, Clock}, State};
        error ->
            Reply = do_read(Key, Type, TxId, latest, State),
            {reply, Reply, State}
    end;

handle_command({read_key_time, Key, Type, TxId, Time}, Sender,
               #state{clock=Clock0, buffered_reads=BufferedReads0, min_pendings=MinPendings}=State) ->
    Clock = max(Clock0, Time),
    case dict:find(Key, MinPendings) of
        {ok, Min} ->
            case Min =< Time of
                true ->
                    Orddict = case dict:find(Key, BufferedReads0) of
                                {ok, Orddict0} ->
                                    orddict:store(Time, {Sender, Type, TxId}, Orddict0);
                                error ->
                                    Orddict0 = orddict:new(),
                                    orddict:store(Time, {Sender, Type, TxId}, Orddict0)
                              end,
                    BufferedReads = dict:store(Key, Orddict, BufferedReads0),
                    {noreply, State#state{clock=Clock, buffered_reads=BufferedReads}};
                false ->
                    Reply = do_read(Key, Type, TxId, Time, State#state{clock=Clock}),
                    {reply, Reply, State#state{clock=Clock}} 
            end;
        error ->
            Reply = do_read(Key, Type, TxId, Time, State#state{clock=Clock}),
            {reply, Reply, State#state{clock=Clock}} 
    end;

handle_command({coordinate_tx, Updates, Deps, Debug}, Sender, #state{partition=Partition}=State) ->
    Vnode = {Partition, node()},
    {ok, _Pid} = eiger_updatetx_coord_fsm:start_link(Vnode, Sender, Updates, Deps, Debug),
    {noreply, State};

handle_command({prepare, Transaction, CoordClock, Keys}, _Sender, #state{clock=Clock0, pending=Pending0, min_pendings=MinPendings0}=State) ->
    Clock = max(Clock0, CoordClock) + 1,
    {Pending, MinPendings} = lists:foldl(fun(Key, {P0, MP0}) ->
                                            P = dict:append(Key, {Clock, Transaction#transaction.txn_id}, P0),
                                            MP = case dict:find(Key, MP0) of
                                                    {ok, _Min} ->
                                                        MP0;
                                                    _ ->
                                                        dict:store(Key, Clock, MP0)
                                                 end,
                                            {P, MP}    
                                        end, {Pending0, MinPendings0}, Keys),
    {reply, {prepared, Clock}, State#state{clock=Clock, pending=Pending, min_pendings=MinPendings}};

handle_command({prepare_replicated, TxId, Keys}, _Sender, #state{clock=Clock, pending=Pending0, min_pendings=MinPendings0}=State) ->
    {Pending, MinPendings} = lists:foldl(fun(Key, {P0, MP0}) ->
                                            P = dict:append(Key, {Clock, TxId}, P0),
                                            MP = case dict:find(Key, MP0) of
                                                    {ok, _Min} ->
                                                        MP0;
                                                    _ ->
                                                        dict:store(Key, Clock, MP0)
                                                 end,
                                            {P, MP}    
                                        end, {Pending0, MinPendings0}, Keys),
    {reply, {prepared, Clock}, State#state{clock=Clock, pending=Pending, min_pendings=MinPendings}};

handle_command({commit_replicated, Transaction, Operations}, _Sender, State0=#state{partition=Partition}) ->
    FirstOp = hd(Operations),
    FirstRecord = FirstOp#operation.payload,
    {Key,_Type,_Op} = FirstRecord#log_record.op_payload,
    LogId = log_utilities:get_logid_from_key(Key),
    Node = {Partition,node()},
    {TxId, {DcId, CommitTime}, VecSnapshotTime, _Ops, _Deps, _TotalOps} = Transaction,
    DownOps = lists:foldl(fun(Op, Acc0) ->
                            Logrecord = Op#operation.payload,
                            case Logrecord#log_record.op_type of
                                update ->
                                    logging_vnode:append(Node, LogId, Logrecord),
                                    {Key1, Type1, Op1} = Logrecord#log_record.op_payload,
                                    NewRecord = #clocksi_payload{
                                        key = Key1,
                                        type = Type1,
                                        op_param = Op1,
                                        snapshot_time = VecSnapshotTime,
                                        commit_time = {DcId, CommitTime},
                                        txid =  Logrecord#log_record.tx_id
                                    },
                                    Acc0 ++ [NewRecord];
                                _ -> %% prepare or commit
                                    logging_vnode:append(Node, LogId, Logrecord),
                                    Acc0
                            end
                          end, [], Operations),
    State1 = lists:foldl(fun(DownOp, S0) ->
                            Key1 = DownOp#clocksi_payload.key,
                            ok = eiger_materializer_vnode:update(Key1, DownOp),
                            post_commit_update(Key1, TxId, CommitTime, S0)
                         end, State0, DownOps),
    {reply, committed, State1};

handle_command({commit, Transaction, Updates, Deps, CommitClock, TotalOps}, _Sender, State0=#state{clock=Clock0}) ->
    Clock = max(Clock0, CommitClock),
    case update_keys(Updates, Deps, Transaction, CommitClock, TotalOps, State0) of
        {ok, State} ->
            {reply, {committed, CommitClock}, State#state{clock=Clock}};
        {error, Reason} ->
            {reply, {error, Reason}, State0#state{clock=Clock}}
    end;

handle_command(get_clock, _Sender, S0=#state{clock=Clock}) ->
    {reply, {ok, Clock}, S0};

handle_command({update_clock, NewClock}, _Sender, S0=#state{clock=Clock0}) ->
    Clock =  max(Clock0, NewClock),
    {reply, ok, S0#state{clock=Clock}};

handle_command(_Message, _Sender, State) ->
    {noreply, State}.

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(_ObjectName, _ObjectValue) ->
    <<>>.

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

update_keys(Ups, Deps, Transaction, CommitTime, TotalOps, State0) ->
    Payloads = lists:foldl(fun(Update, Acc) ->
                    {Key, Type, _} = Update,
                    TxId = Transaction#transaction.txn_id,
                    LogRecord = #log_record{tx_id=TxId, op_type=update, op_payload={Key, Type, Update}},
                    LogId = log_utilities:get_logid_from_key(Key),
                    [Node] = log_utilities:get_preflist_from_key(Key),
                    DcId = dc_utilities:get_my_dc_id(),
                    {ok, _} = logging_vnode:append(Node,LogId,LogRecord),
                    CommittedOp = #clocksi_payload{
                                            key = Key,
                                            type = Type,
                                            op_param = Update,
                                            snapshot_time = Transaction#transaction.vec_snapshot_time,
                                            commit_time = {DcId, CommitTime},
                                            txid = Transaction#transaction.txn_id},
                    [CommittedOp|Acc] end, [], Ups),
    FirstOp = hd(Ups),
    {Key, _, _} = FirstOp,
    LogId = log_utilities:get_logid_from_key(Key),
    [Node] = log_utilities:get_preflist_from_key(Key),
    TxId = Transaction#transaction.txn_id,
    PreparedLogRecord = #log_record{tx_id=TxId,
                                    op_type=prepare,
                                    op_payload=CommitTime},
    logging_vnode:append(Node,LogId,PreparedLogRecord),
    DcId = dc_utilities:get_my_dc_id(),
    CommitLogRecord=#log_record{tx_id=TxId,
                                op_type=commit,
                                op_payload={{DcId, CommitTime}, Transaction#transaction.vec_snapshot_time, Deps, TotalOps}},
    case logging_vnode:append(Node,LogId,CommitLogRecord) of
        {ok, _} ->
            State = lists:foldl(fun(Op, S0) ->
                                    Key = Op#clocksi_payload.key,
                                    %% This can only return ok, it is therefore pointless to check the return value.
                                    eiger_materializer_vnode:update(Key, Op),
                                    post_commit_update(Key, TxId, CommitTime, S0)
                                end, State0, Payloads),
            {ok, State};
        {error, timeout} ->
            error
    end.
    
post_commit_update(Key, TxId, CommitTime, State0=#state{pending=Pending0, min_pendings=MinPendings0, buffered_reads=BufferedReads0, clock=Clock}) ->
    List0 = dict:fetch(Key, Pending0),
    {List, PrepareTime} = delete_pending_entry(List0, TxId, []),
    case List of
        [] ->
            Pending = dict:erase(Key, Pending0),
            MinPendings = dict:erase(Key, MinPendings0),
            case dict:find(Key, BufferedReads0) of
                {ok, Orddict0} ->
                    lists:foreach(fun({Time, {Client, TypeB, TxIdB}}) ->
                                    Reply = do_read(Key, TypeB, TxIdB, Time, State0),
                                    riak_core_vnode:reply(Client, Reply)
                                  end, Orddict0),
                    BufferedReads=dict:erase(Key, BufferedReads0),
                    State=State0#state{pending=Pending, min_pendings=MinPendings, buffered_reads=BufferedReads};
                error ->
                    State=State0#state{pending=Pending, min_pendings=MinPendings}
            end;
        _ ->
            Pending = dict:store(Key, List, Pending0),
            case dict:fetch(Key, MinPendings0) < PrepareTime of
                true ->
                    State=State0#state{pending=Pending};
                false ->
                    Times = [PT || {_TxId, PT} <- List],
                    Min = lists:min(Times),
                    MinPendings =  dict:store(Key, Min, MinPendings0),
                    case dict:find(Key, BufferedReads0) of
                        {ok, Orddict0} ->
                            case handle_pending_reads(Orddict0, CommitTime, Key, Clock) of
                                [] ->
                                    BufferedReads = dict:erase(Key, BufferedReads0);
                                Orddict ->
                                    BufferedReads = dict:store(Key, Orddict, BufferedReads0)
                            end,
                            State=State0#state{pending=Pending, min_pendings=MinPendings, buffered_reads=BufferedReads};
                        error ->
                            State=State0#state{pending=Pending, min_pendings=MinPendings}
                    end
            end
    end,
    State.

delete_pending_entry([], _TxId, List) ->
    {List, not_found};

delete_pending_entry([Element|Rest], TxId, List) ->
    case Element of
        {PrepareTime, TxId} ->
            {List ++ Rest, PrepareTime};
        _ ->
            delete_pending_entry(Rest, TxId, List ++ [Element])
    end.

handle_pending_reads([], _CommitTime, _Key, _Clock) ->
    [];

handle_pending_reads([Element|Rest], CommitTime, Key, Clock) ->
    {Time, Type, TxId, Client} = Element,
    case Time < CommitTime of
        true ->
            Reply = do_read(Key, Type, TxId, Time, #state{clock=Clock}),
            riak_core_vnode:reply(Client, Reply),
            handle_pending_reads(Rest, CommitTime, Key, Clock);
        false ->
            [Element|Rest]
    end.

do_read(Key, Type, TxId, Time, #state{clock=Clock}) -> 
    case eiger_materializer_vnode:read(Key, Type, Time, TxId) of
    %case eiger_materializer_vnode:read(Key, Time) of
        {ok, Snapshot, {_CoordId, EVT}} ->
            Value = Type:value(Snapshot),
            lager:info("Snapshot is ~w, EVT is ~w", [Snapshot, EVT]),
            case Time of
                latest -> 
                    {Key, Value, EVT, Clock};
                _ -> 
                    {Key, Value, EVT}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
