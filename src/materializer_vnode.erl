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
-module(materializer_vnode).

-behaviour(riak_core_vnode).

-include("floppy.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").


-define(SNAPSHOT_THRESHOLD, 10).
-define(SNAPSHOT_MIN, 2).
-define(OPS_THRESHOLD, 50).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_vnode/1,
         read/3,
         update/2]).

-export([init/1,
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

-record(state, {partition, ops_cache, snapshot_cache}).

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

%% @doc Read state of key at given snapshot time
-spec read(key(), type(), vectorclock:vectorclock()) -> {ok, term()} | {error, atom()}.
read(Key, Type, SnapshotTime) ->
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Key)}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, 1, materializer),
    [{NewPref,_}] = Preflist,
    riak_core_vnode_master:sync_command(NewPref,
                                        {read, Key, Type, SnapshotTime},
                                        materializer_vnode_master).

%%@doc write downstream operation to persistant log and ops_cache it for future read
-spec update(key(), #clocksi_payload{}) -> ok | {error, atom()}.
update(Key, DownstreamOp) ->
    DocIdx = riak_core_util:chash_key({?BUCKET, term_to_binary(Key)}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, 1, materializer),
    [{NewPref,_}] = Preflist,
    riak_core_vnode_master:sync_command(NewPref, {update, Key, DownstreamOp},
                                        materializer_vnode_master).

init([Partition]) ->
    OpsCache = ets:new(ops_cache, [set]),
    SnapshotCache = ets:new(snapshot_cache, [set]),
    {ok, #state{partition=Partition, ops_cache=OpsCache, snapshot_cache=SnapshotCache}}.

handle_command({read, Key, Type, SnapshotTime}, Sender,
		State = #state{ops_cache=OpsCache, snapshot_cache=SnapshotCache}) ->
	ok=internal_read(Sender, Key, Type, SnapshotTime, OpsCache, SnapshotCache),
	{noreply, State};	  

handle_command({update, Key, DownstreamOp}, Sender,
               State = #state{ops_cache = OpsCache, snapshot_cache=SnapshotCache})->
    ok=internal_update(Sender, Key, DownstreamOp, OpsCache, SnapshotCache),
    {noreply, State};
    
handle_command(_Message, _Sender, State) ->
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0} ,
                       _Sender,
                       State = #state{ops_cache = OpsCache}) ->
    F = fun({Key,Operation}, A) ->
                Fun(Key, Operation, A)
        end,
    Acc = ets:foldl(F, Acc0, OpsCache),
    {reply, Acc, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, State = #state{ops_cache = OpsCache}) ->
    {Key, Operation} = binary_to_term(Data),
    true = ets:insert(OpsCache, {Key, Operation}),
    {reply, ok, State}.

encode_handoff_item(Key, Operation) ->
    term_to_binary({Key, Operation}).

is_empty(State=#state{ops_cache = OpsCache}) ->
    case ets:first(OpsCache) of
        '$end_of_table' ->
            {true, State};
        _ ->
            {false, State}
    end.

delete(State=#state{ops_cache=OpsCache}) ->
    true = ets:delete(OpsCache),
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.



%%---------------- Internal Functions -------------------%%

%% @doc This function takes care of reading. It is implemented here for not blocking the 
%% vnode when the write function calls it. That is done for garbage collection. 
-spec internal_read(term(),term(), atom(), vectorclock:vectorclock(), atom() , atom() ) -> ok.
internal_read(Sender, Key, Type, SnapshotTime, OpsCache, SnapshotCache) ->
    % get the latest snapshot for the key
    case ets:lookup(SnapshotCache, Key) of
    	[] ->
    		NewSnapshot=Type:new(),
            case ets:lookup(OpsCache, Key) of
            [] ->
            	riak_core_vnode:reply(Sender, {ok, NewSnapshot});
            [{_, OpsDict}] ->
            	{ok, Ops}= filter_ops(OpsDict),
            	LastOp=lists:last(Ops),
            	lager:info("Last Op is: ~p", [LastOp]),
            	TxId = LastOp#clocksi_payload.txid,
            	{ok, Snapshot, CommitTime} = clocksi_materializer:update_snapshot(Type, NewSnapshot, SnapshotTime, Ops, TxId),
            	riak_core_vnode:reply(Sender, {ok, Snapshot}),
            	SnapshotDict=orddict:new(),
            	ets:insert(SnapshotCache, {Key, orddict:store(CommitTime,Snapshot, SnapshotDict)})
            end;
        [{_, SnapshotDict}] -> 
            case get_latest_snapshot(SnapshotDict, SnapshotTime) of
			{ok, {_SnapshotCommitTime, LatestSnapshot}}->
				case ets:lookup(OpsCache, Key) of
				[] ->
					riak_core_vnode:reply(Sender, {ok, LatestSnapshot});
				[{_, OpsDict}] ->
					{ok, Ops}= filter_ops(OpsDict),
					LastOp=lists:last(Ops),
					TxId = LastOp#clocksi_payload.txid,
					{ok, Snapshot, CommitTime} = clocksi_materializer:update_snapshot(Type, LatestSnapshot, SnapshotTime, Ops, TxId),
					case (Sender /= ignore) of
					true ->
						riak_core_vnode:reply(Sender, {ok, Snapshot});
					false ->
						false
					end,
					SnapshotDict1=orddict:store(CommitTime,Snapshot, SnapshotDict),
					snapshot_insert_gc(Key,SnapshotDict1, OpsDict, SnapshotCache, OpsCache)
				end;
			{error, no_snapshot} ->
				%%FIX THIS, READ FROM THE LOG WHEN THERE IS NO SNAPSHOT.
				riak_core_vnode:reply(Sender, {error, no_snapshot})
			end	
    end,
    ok.
	%TODO: trigger the GC mechanism asynchronously
	
	
%% @doc This function takes care of appending an operation to the log and
%%  to the cache.	
-spec internal_update(term(), Key::term(), DownstreamOp::clocksi_payload(), 
		OpsCache::atom(), SnapshotCache::atom()) ->	ok.
internal_update(Sender, Key, DownstreamOp, OpsCache, SnapshotCache) ->	
%% TODO: Remove unnecessary information from op_payload in log_Record
    LogRecord = #log_record{tx_id=DownstreamOp#clocksi_payload.txid,
                            op_type=downstreamop,
                            op_payload=DownstreamOp},
    LogId = log_utilities:get_logid_from_key(Key),
    [Node] = log_utilities:get_preflist_from_key(Key),
    %% TODO: what if all of the following was done asynchronously?
    case logging_vnode:append(Node,LogId,LogRecord) of
        {ok, _} ->
        	riak_core_vnode:reply(Sender, ok),
        	case ets:lookup(OpsCache, Key) of
        	[]->
        		OpsDict=orddict:new();
        	[{_, OpsDict}]->
        		OpsDict
        	end,        	
        	op_insert_gc(Key,DownstreamOp, OpsDict, OpsCache, SnapshotCache),
            ok;
        {error, Reason} ->
            riak_core_vnode:reply(Sender, {error, Reason})
    end.


%% @doc Obtains, from an orddict of Snapshots, the latest snapshot that can be included in 
%% a snapshot identified by SnapshotTime
-spec get_latest_snapshot(SnapshotDict::orddict:orddict(), SnapshotTime::vectorclock:vectorclock())
	 -> {ok, term()} | {error, no_snapshot}| {error, wrong_format, term()}.
get_latest_snapshot(SnapshotDict, SnapshotTime) ->
	case SnapshotDict of
	[]->
		{ok,[]};
	[H|T]->
		case orddict:filter(fun(Key, _Value) -> 
				belongs_to_snapshot(Key, SnapshotTime) end, [H|T]) of 
			[]->
		        {error,no_snapshot};
		    [H1|T1]->
				{CommitTime, Snapshot} = lists:last([H1|T1]),
				{ok, {CommitTime, Snapshot}}
        end;
    Anything ->
    	{error, wrong_format, Anything}
	end.

%% @doc Get a list of operations from an orddict of operations
-spec filter_ops(orddict:orddict()) -> {ok, list()} | {error, wrong_format}.
filter_ops(Ops) ->
	filter_ops(Ops, []).
-spec filter_ops(orddict:orddict(), list()) -> {ok, list()} | {error, wrong_format}.
filter_ops([], Acc) ->
	{ok, Acc};
filter_ops([H|T], Acc) ->
	case H of 
	{_Key, Ops} ->
		filter_ops(T,lists:append(Acc, Ops));
	_ ->
		{error, wrong_format}
	end;
filter_ops(_, _Acc) ->
	{error, wrong_format}.
	
    
%% @doc Check whether a Key's operation or stored snapshot is included
%%		in a snapshot defined by a vector clock
%%      Input: Dc = Datacenter Id
%%             CommitTime = local commit time of this Snapshot at DC
%%             SnapshotTime = vector clock
%%      Outptut: true or false
-spec belongs_to_snapshot({Dc::term(),CommitTime::non_neg_integer()},
                        SnapshotTime::vectorclock:vectorclock()) -> boolean()|error.
belongs_to_snapshot({Dc, CommitTime}, SnapshotTime) ->
    case vectorclock:get_clock_of_dc(Dc, SnapshotTime) of
        {ok, Ts} ->
            CommitTime =< Ts;
        error  ->
            error
    end.

%% @doc Operation to insert a Snapshot in the cache and start 
%%      Garbage collection triggered by reads.
-spec snapshot_insert_gc(Key::term(), SnapshotDict::orddict:orddict(), 
	OpsDict::orddict:orddict(), atom() , atom() ) -> true.
snapshot_insert_gc(Key, SnapshotDict, OpsDict, SnapshotCache, OpsCache)-> 
	case (orddict:size(SnapshotDict))==?SNAPSHOT_THRESHOLD of 
	true ->
		PrunedSnapshots=orddict:from_list(lists:sublist(orddict:to_list(SnapshotDict), 1+?SNAPSHOT_THRESHOLD-?SNAPSHOT_MIN, ?SNAPSHOT_MIN)),
		FirstOp=lists:nth(1, PrunedSnapshots),
		{CommitTime, _S} = FirstOp,
		PrunedOps=prune_ops(OpsDict, CommitTime),
		ets:insert(SnapshotCache, {Key, PrunedSnapshots}),
        ets:insert(OpsCache, {Key, PrunedOps});
	false ->
		ets:insert(SnapshotCache, {Key, SnapshotDict})
	end.
	
%% @doc Remove from OpsDict all operations that have committed before Threshold. 
-spec prune_ops(orddict:orddict(), {Dc::term(),CommitTime::non_neg_integer()})-> orddict:orddict().	
prune_ops(OpsDict, Threshold)->
	orddict:filter(fun(_Key, Value) -> 
				(belongs_to_snapshot(Threshold,(lists:last(Value))#clocksi_payload.snapshot_time)) end, OpsDict).


%% @doc Insert an operation and start garbage collection triggered by writes.
%% the mechanism is very simple; when there are more than OPS_THRESHOLD
%% operations for a given key, just perform a read, that will trigger
%% the GC mechanism.
-spec op_insert_gc(term(), clocksi_payload(), 
	orddict:orddict(), atom() , atom() )-> true.
op_insert_gc(Key,DownstreamOp, OpsDict, OpsCache, SnapshotCache)-> 
    case (orddict:size(OpsDict))>=?OPS_THRESHOLD of 
    true ->
	    Type=DownstreamOp#clocksi_payload.type,
	    SnapshotTime=DownstreamOp#clocksi_payload.snapshot_time,
	    Type=DownstreamOp#clocksi_payload.type,
	    SnapshotTime=DownstreamOp#clocksi_payload.snapshot_time,
	    ok=internal_read(ignore, Key, Type, SnapshotTime, OpsCache, SnapshotCache),
	    OpsDict1=orddict:append(DownstreamOp#clocksi_payload.commit_time, DownstreamOp, OpsDict),
		ets:insert(OpsCache, {Key, OpsDict1});
	false ->
		OpsDict1=orddict:append(DownstreamOp#clocksi_payload.commit_time, DownstreamOp, OpsDict),
		ets:insert(OpsCache, {Key, OpsDict1})
    end.

     
-ifdef(TEST). 

%% @doc Testing filter_ops works in both situations, when the function receives
%%      what it expects and when it receives something in an unexpected format.
filter_ops_test() ->
	Ops=orddict:new(),
	Ops1=orddict:append(key1, [a1, a2], Ops),
	Ops2=orddict:append(key2, [b1, b2], Ops1),
	Ops3=orddict:append(key3, [c1, c2], Ops2),
	Result=filter_ops(Ops3),
	?assertEqual(Result, {ok, [[a1,a2], [b1,b2], [c1,c2]]}),
	Result1=filter_ops({some, thing}),
	?assertEqual(Result1, {error, wrong_format}),
	Result2=filter_ops([anything]),
	?assertEqual(Result2, {error, wrong_format}).   
-endif.

    
    
