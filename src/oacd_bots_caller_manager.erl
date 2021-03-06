%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License at
%%  http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%  License for the specific language governing rights and limitations
%%  under the License.
%%
%%  The Original Code is "oacd_bots".
%%
%%  The Initial Developer of the Original Code is Micah Warren <micahw at 
%%  lordnull dot com>
%%  Portions created by Micah Warren <micahw at lordnull dot com> are 
%%  Copyright (C) 2011.  
%%  All Rights Reserved.
%%
%%  Contributor(s): Micah Warren <micahw at lordnull dot com>

-module(oacd_bots_caller_manager).
-author("Micah Warren").
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-record(state, {
	freeswitch :: atom(),
	check_timer :: 'undefined' | reference(),
	callers = dict:new()
}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1, start_link/2]).
-export([spawn_call/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
	code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Freeswitch) ->
	start_link(Freeswitch, []).

start_link(Freeswitch, Options) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, {Freeswitch, Options}, []).

spawn_call(TargetNumber) ->
	gen_server:cast(?SERVER, {spawn_call, TargetNumber}).

%% ==================================================================
%% gen_server Function Definitions
%% ==================================================================

%% ------------------------------------------------------------------
%% INIT
%% ------------------------------------------------------------------

init({Freeswitch, Options}) ->
	process_flag(trap_exit, true),
	monitor_node(Freeswitch, true),
	lager:info("~s started with freeswitch node ~p", [?MODULE, Freeswitch]),
  {ok, #state{freeswitch = Freeswitch}}.

%% ------------------------------------------------------------------
%% handle_call
%% ------------------------------------------------------------------

handle_call(_Request, _From, State) ->
  {noreply, ok, State}.

%% ------------------------------------------------------------------
%% handle_cast
%% ------------------------------------------------------------------

handle_cast({spawn_call, TargetNum}, #state{freeswitch = Fsnode} = State) ->
	{ok, UUID} = freeswitch:api(Fsnode, create_uuid),
	Opts = [{originate, TargetNum}, {uuid, UUID}],
	{ok, Pid} = oacd_bots_caller:start_link(Fsnode, Opts),
	NewDict = dict:store(UUID, Pid, State#state.callers),
	lager:info("UUID ~s now associated with ~p.", [UUID, Pid]),
	{noreply, State#state{callers = NewDict}};

handle_cast(_Msg, State) ->
  {noreply, State}.

%% ------------------------------------------------------------------
%% handle_info
%% ------------------------------------------------------------------

handle_info(check_freeswitch, #state{freeswitch = Fsnode} = State) ->
	CheckTimer = case net_adm:ping(Fsnode) of
		pang -> 
			lager:warning("Freeswitch not available, checking again in 5 seconds"),
			erlang:send_after(5000, self(), check_freeswitch);
		pong -> 
			monitor_node(Fsnode, true),
			undefined
	end,
	{noreply, State#state{check_timer = CheckTimer}};

handle_info({get_pid, UUID, Ref, From}, #state{callers = Callers} = State) ->
	case dict:find(UUID, Callers) of
		{ok, Pid} ->
			From ! {Ref, Pid},
			{noreply, State};
		error ->
			StartOpts = [{uuid, UUID}, {originate, false}],
			case oacd_bots_caller:start_link(State#state.freeswitch, StartOpts) of
				{ok, Pid} ->
					From ! {Ref, Pid},
					NewDict = dict:store(UUID, Pid, Callers),
					lager:info("~s is now associated with ~p", [UUID, Pid]),
					{noreply, State#state{callers = NewDict}};
				Else ->
					lager:error("~s could not be associated with a pid due to ~p", [UUID, Else]),
					From ! {Ref, Else},
					{noreply, State}
			end
	end;

handle_info({nodedown, Fsnode}, #state{freeswitch = Fsnode, check_timer = undefined} = State) ->
	lager:warning("Freeswitch has gone down, checking in 5 seconds"),
	CheckTimer = erlang:send_after(5000, self(), check_freeswitch),
	{noreply, State#state{check_timer = CheckTimer}};

handle_info({nodedown, Fsnode}, State) ->
	lager:debug("Already got a node down notification, ignoring"),
	{noreply, State};

handle_info({'EXIT', Pid, Reason}, #state{callers = Callers} = State) ->
	lager:info("~p exited", [Pid]),
	NewDict = dict:filter(fun(Key, Value) ->
		Value =/= Pid
	end, Callers),
	{noreply, State#state{callers = NewDict}};
		
handle_info(Info, State) ->
	lager:info("da info:  ~p", [Info]),
  {noreply, State}.

%% ------------------------------------------------------------------
%% terminate
%% ------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
