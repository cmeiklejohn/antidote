-module(floppy_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_rep/1]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc: start_rep(Port) - starts a server which listens for incomming
%% tcp connection on port Port. Server receives updates to replicate 
%% from other DCs 
start_rep(Port) ->
    supervisor:start_child(?MODULE, {inter_dc_communication_sup,
                    {inter_dc_communication_sup, start_link, [Port]},
                    permanent, 5000, supervisor, [inter_dc_communication_sup]}).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init(_Args) ->
    LoggingMaster = {logging_vnode_master,
                     {riak_core_vnode_master, start_link, [logging_vnode]},
                     permanent, 5000, worker, [riak_core_vnode_master]},
    RepMaster = {floppy_rep_vnode_master,
                 {riak_core_vnode_master, start_link, [floppy_rep_vnode]},
                 permanent, 5000, worker, [riak_core_vnode_master]},
    ClockSIMaster = { clocksi_vnode_master,
                      {riak_core_vnode_master, start_link, [clocksi_vnode]},
                      permanent, 5000, worker, [riak_core_vnode_master]},

    InterDcRepMaster = {inter_dc_repl_vnode_master,
                        {riak_core_vnode_master, start_link,
                         [inter_dc_repl_vnode]},
                        permanent, 5000, worker, [riak_core_vnode_master]},

    InterDcRecvrMaster = { inter_dc_recvr_vnode_master,
                           {riak_core_vnode_master, start_link,
                            [inter_dc_recvr_vnode]},
                           permanent, 5000, worker, [riak_core_vnode_master]},

    ClockSITxCoordSup =  { clocksi_tx_coord_sup,
                           {clocksi_tx_coord_sup, start_link, []},
                           permanent, 5000, supervisor, [clockSI_tx_coord_sup]},

    ClockSIiTxCoordSup =  { clocksi_interactive_tx_coord_sup,
                            {clocksi_interactive_tx_coord_sup, start_link, []},
                            permanent, 5000, supervisor,
                            [clockSI_interactive_tx_coord_sup]},

    ClockSIDSGenMaster = { clocksi_downstream_generator_vnode_master,
                           {riak_core_vnode_master,  start_link,
                            [clocksi_downstream_generator_vnode]},
                           permanent, 5000, worker, [riak_core_vnode_master]},

    VectorClockMaster = {vectorclock_vnode_master,
                         {riak_core_vnode_master,  start_link,
                          [vectorclock_vnode]},
                         permanent, 5000, worker, [riak_core_vnode_master]},

    MaterializerMaster = {materializer_vnode_master,
                          {riak_core_vnode_master,  start_link,
                           [materializer_vnode]},
                          permanent, 5000, worker, [riak_core_vnode_master]},

    CoordSup =  {floppy_coord_sup,
                 {floppy_coord_sup, start_link, []},
                 permanent, 5000, supervisor, [floppy_coord_sup]},
    RepSup = {floppy_rep_sup,
              {floppy_rep_sup, start_link, []},
              permanent, 5000, supervisor, [floppy_rep_sup]},
   
    {ok,
     {{one_for_one, 5, 10},
      [LoggingMaster,
       RepMaster,
       ClockSIMaster,
       ClockSITxCoordSup,
       ClockSIiTxCoordSup,
       InterDcRepMaster,
       InterDcRecvrMaster,
       CoordSup,
       RepSup,
       ClockSIDSGenMaster,
       VectorClockMaster,
       MaterializerMaster]}}.
