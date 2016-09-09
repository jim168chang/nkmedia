%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Session Management
-module(nkmedia_session).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, get_type/1, get_session/1, get_offer/1, get_answer/1]).
-export([set_answer/2, set_type/3, cmd/3, cmd_async/3, info/2]).
-export([stop/1, stop/2, stop_all/0]).
-export([candidate/2]).
-export([register/2, unregister/2, link_from_slave/2, unlink_session/1, unlink_session/2]).
-export([get_all/0, bridge_stop/2, get_session_file/1]).
-export([set_slave_answer/3, peer_candidate/3]).
-export([find/1, do_cast/2, do_call/2, do_call/3, do_info/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, config/0, session/0, event/0, type_ext/0]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Session ~s (~p) "++Txt, 
               [State#state.id, State#state.type | Args])).

-include("nkmedia.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").

-define(MAX_ICE_TIME, 1000).
-define(MAX_CALL_TIME, 5000).

%% ===================================================================
%% Types
%% ===================================================================


-type id() :: binary().


%% Backend plugins expand the available types
-type type() :: p2p | atom().


%% Backend plugins expand the available types
-type cmd() :: term().


%% Session configuration
%% If we set a master session, we will set this as a 'slave' of that 'master' session
%% If one of them stops, the other one will also stop.
%% If the slave has an answer, it will invoke nkmedia_session_slave_answer in master
%% If it has an ICE candidate to send, it will invoke nkmedia_session_peer_candidate
%% in master instead of sending the event {candidate, Candidate}
%% If the master has an ICE candidate to send, will invoke nkmedia_session_peer_candidate
%% in slave
-type config() :: 
    #{
        session_id => id(),                         % Generated if not included
        no_offer_trickle_ice => boolean(),          % Buffer candidates and insert in SDP
        no_answer_trickle_ice => boolean(),       
        backend => nkemdia:backend(),
        master_id => id(),                          % See above
        % set_master_answer => boolean(),             
        register => nklib:link(),
        wait_timeout => integer(),                  % Secs
        ready_timeout => integer(),
        user_id => nkservice:user_id(),             % Informative only
        user_session => nkservice:user_session(),   % Informative only
        term() => term()                            % Plugin data
    }.


-type session() ::
    config () | 
    #{
        srv_id => nkservice:id(),
        backend_role => offerer | offeree,
        type => type(),
        type_ext => type_ext(),
        master_peer => id(),
        slave_peer => id(),
        record_pos => integer(),                     % Record position
        player_loops => boolean() |integer()
    }.


-type type_ext() :: map().


-type event() ::
    {offer, nkmedia:offer()}                            | 
    {answer, nkmedia:answer()}                          | 
    {session_type, atom(), map()}                       |
    {candidate, nkmedia:candidate()}                    |
    {info, binary()}                                    |   % User info
    {stop, nkservice:error()} .                             % Session is about to hangup


-type from() :: {pid(), term()}.


% ===================================================================
% Public
% ===================================================================

%% @private
-spec start(nkservice:id(), type(), config()) ->
    {ok, id(), pid()} | {error, nkservice:error()}.

start(Srv, Type, Config) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Config2 = Config#{type=>Type, srv_id=>SrvId},
            {SessId, Config3} = nkmedia_util:add_id(session_id, Config2),
            {ok, SessPid} = gen_server:start(?MODULE, [Config3], []),
            {ok, SessId, SessPid};
        not_found ->
            {error, service_not_found}
    end.


%% @doc Get current session data
-spec get_session(id()) ->
    {ok, session()} | {error, nkservice:error()}.

get_session(SessId) ->
    do_call(SessId, get_session).


%% @doc Get current session offer
-spec get_offer(id()) ->
    {ok, nkmedia:offer()} | {error, nkservice:error()}.

get_offer(SessId) ->
    do_call(SessId, get_offer, ?MAX_CALL_TIME).


%% @doc Get current session answer
-spec get_answer(id()) ->
    {ok, nkmedia:answer()} | {error, nkservice:error()}.

get_answer(SessId) ->
    do_call(SessId, get_answer, ?MAX_CALL_TIME).


%% @doc Get current type, type_ext and remaining time to timeout
-spec get_type(id()) ->
    {ok, type(), type_ext(), integer()} | {error, term()}.

get_type(SessId) ->
    do_call(SessId, get_type).


%% @doc Hangups the session
-spec stop(id()) ->
    ok | {error, nkservice:error()}.

stop(SessId) ->
    stop(SessId, user_stop).


%% @doc Hangups the session
-spec stop(id(), nkservice:error()) ->
    ok | {error, nkservice:error()}.

stop(SessId, Reason) ->
    do_cast(SessId, {stop, Reason}).


%% @private Hangups all sessions
stop_all() ->
    lists:foreach(fun({SessId, _Pid}) -> stop(SessId) end, get_all()).


%% @doc Sets the session's current answer operation.
-spec set_answer(id(), nkmedia:answer()) ->
    ok | {error, nkservice:error()}.

set_answer(SessId, Answer) ->
    do_cast(SessId, {set_answer, Answer}).


%% @doc Updates the session's current type
-spec set_type(id(), type(), type_ext()) ->
    ok | {error, nkservice:error()}.

set_type(SessId, Type, TypeExt) ->
    do_cast(SessId, {set_type, Type, TypeExt}).


%% @doc Sends a ICE candidate
%% The type field can select if it is for the offer or the answer
%% If it is undefined, will be offer for 'offeree' role and answer for 'offerer'
-spec candidate(id(), nkmedia:candidate()) ->
    ok | {error, term()}.

candidate(SessId, #candidate{}=Candidate) ->
    do_cast(SessId, {candidate, Candidate}).


%% @doc Sends a command to the session
-spec cmd(id(), cmd(), Opts::map()) ->
    {ok, term()} | {error, nkservice:error()}.

cmd(SessId, Cmd, Opts) ->
    do_call(SessId, {cmd, Cmd, Opts}).


%% @doc Equivalent to cmd/3, but does not wait for operation's result
-spec cmd_async(id(), cmd(), Opts::map()) ->
    ok | {error, nkservice:error()}.

cmd_async(SessId, Cmd, Opts) ->
    do_cast(SessId, {cmd, Cmd, Opts}).


%% @doc Sends an info to the sesison
-spec info(id(), binary()) ->
    ok | {error, nkservice:error()}.

info(SessId, Info) ->
    do_cast(SessId, {info, nklib_util:to_binary(Info)}).


%% @doc Links this session to another. We are master, other is slave
-spec link_from_slave(id(), id()) ->
    {ok, pid()} | {error, nkservice:error()}.

link_from_slave(MasterId, SlaveId) ->
    case find(SlaveId) of
        {ok, PidB} ->
            do_call(MasterId, {link_to_slave, SlaveId, PidB});
        not_found ->
            {error, peer_session_not_found}
    end.


%% @doc Unkinks this session from its peer 
-spec unlink_session(id()) ->
    ok | {error, nkservice:error()}.

unlink_session(SessId) ->
    do_cast(SessId, unlink_session).


%% @doc Unkinks this session from its peer 
-spec unlink_session(id(), id()) ->
    ok | {error, nkservice:error()}.

unlink_session(SessId, PeerId) ->
    do_cast(SessId, {unlink_session, PeerId}).


%% @doc Registers a process with the session
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkservice:error()}.

register(SessId, Link) ->
    case find(SessId) of
        {ok, Pid} -> 
            do_cast(Pid, {register, Link}),
            {ok, Pid};
        not_found ->
            {error, session_not_found}
    end.


%% @doc Unregisters a process with the session
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkservice:error()}.

unregister(SessId, Link) ->
    do_cast(SessId, {unregister, Link}).


%% @private
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% ===================================================================
%% Internal
%% ===================================================================


% %% @doc Sends a client ICE candidate from the backend
% -spec backend_candidate(id(), nkmedia:candidate()) ->
%     ok | {error, term()}.

% backend_candidate(SessId, Candidate) ->
%     do_cast(SessId, {backend_candidate, Candidate}).


%% @private
-spec get_session_file(session()) ->
    {binary(), session()}.

get_session_file(#{session_id:=SessId}=Session) ->
    Pos = maps:get(record_pos, Session, 0),
    Name = list_to_binary(io_lib:format("~s_p~4..0w.webm", [SessId, Pos])),
    {Name, ?SESSION(#{record_pos=>Pos+1}, Session)}.


%% @private Called when a bridged session stops to call nkmedia_session_bridge_stop
%% callback
-spec bridge_stop(id(), session()) ->
    {ok, session()} | {stop, session()}.

bridge_stop(PeerId, #{srv_id:=SrvId}=Session) ->
    SrvId:nkmedia_session_bridge_stop(PeerId, Session).


%% @private
-spec set_slave_answer(id(), id(), nkmedia:answer()) ->
    ok | {error, term()}.

set_slave_answer(MasterId, SlaveId, Answer) ->
    do_cast(MasterId, {set_slave_answer, SlaveId, Answer}).


%% @private
-spec peer_candidate(id(), id(), nkmedia:candidate()) ->
    ok | {error, term()}.

peer_candidate(MasterId, SlaveId, Candidate) ->
    do_cast(MasterId, {peer_candidate, SlaveId, Candidate}).


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    id :: id(),
    srv_id :: nkservice:id(),
    backend_role :: offerer | offeree,
    type :: type(),
    type_ext :: type_ext(),
    has_offer = false :: boolean(),
    has_answer = false :: boolean(),
    timer :: reference(),
    wait_offer = [] :: [from()],
    wait_answer = [] :: [from()],
    stop_sent = false :: boolean(),
    links :: nklib_links:links(),
    offer_candidates = trickle :: trickle | last | [nkmedia:candidate()],
    answer_candidates = trickle :: trickle | last | [nkmedia:candidate()],
    session :: session()
}).


%% @private
-spec init(term()) ->
    {ok, #state{}} | {error, term()}.

init([#{session_id:=Id, type:=Type, srv_id:=SrvId}=Session]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    MasterId = maps:get(master_id, Session, undefined),
    % If there is no offer, the backed must make one (offerer)
    % If there is an offer, the backend must make the answer (offeree)
    % unless this is a slave session, where the offer is not from the
    % client, but from other session. We are an offerer (we 'made' the offer)
    % and wait an answer from the client
    Role = case maps:is_key(offer, Session) of
        true when Type==p2p, MasterId/=undefined -> offerer;
        true -> offeree;
        false -> offerer
    end,
    Session2 = Session#{
        backend_role => Role,       
        type => Type,
        type_ext => #{},
        start_time => nklib_util:l_timestamp()
    },
    Session3 = case Type of
        p2p -> Session2#{backend=>p2p};
        _ -> Session2
    end,
    State1 = #state{
        id = Id, 
        srv_id = SrvId, 
        backend_role = Role,
        type = Type,
        type_ext = #{},
        links = nklib_links:new(),
        session = Session3
    },
    State2 = case Session3 of
        #{register:=Link} ->
            links_add(Link, State1);
        _ ->
            State1
    end,
    case MasterId of
        undefined ->
            ok;
        _ ->
            case link_from_slave(MasterId, Id) of
                {ok, _} -> 
                    ok;
                {error, _Error} -> 
                    stop(self(), peer_stopped1)
            end
    end,
    lager:info("NkMEDIA Session ~s (~p) starting (~p)", [Id, Role, self()]),
    lager:info("NkMEDIA Session config: ~p", [maps:remove(offer, Session3)]),
    gen_server:cast(self(), do_start),
    handle(nkmedia_session_init, [Id], State2).
        

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({cmd, set_answer, #{answer:=Answer}}, _From, State) ->
    case do_set_answer(Answer, State) of
        {ok, State2} ->
            reply({ok, #{}}, State2);
        {error, Error, State2} ->
            reply({error, Error}, State2)
    end;

handle_call({cmd, Cmd, Opts}, _From, State) ->
    {Reply, State2} = do_cmd(Cmd, Opts, State),
    reply(Reply, State2);

handle_call({link_to_slave, SlaveId, PidB}, _From, #state{id=MasterId}=State) ->
    % We are Master of SlaveId
    ?LLOG(info, "linked to slave session ~s", [SlaveId], State),
    do_cast(PidB, {link_to_master, MasterId, self()}),
    State2 = links_add({slave_peer, SlaveId}, PidB, State),
    State3 = add_to_session(slave_peer, SlaveId, State2),
    reply({ok, self()}, State3);

handle_call(get_session, _From, #state{session=Session}=State) ->
    reply({ok, Session}, State);

handle_call(get_type, _From, #state{type=Type, timer=Timer, session=Session}=State) ->
    #{type_ext:=TypeExt} = Session,
    reply({ok, Type, TypeExt, erlang:read_timer(Timer) div 1000}, State);

handle_call(get_offer, _From, #state{has_offer=true, session=Session}=State) -> 
    reply({ok, maps:get(offer, Session)}, State);

handle_call(get_offer, From, #state{wait_offer=Wait}=State) -> 
    noreply(State#state{wait_offer=[From|Wait]});

handle_call(get_answer, _From, #state{has_answer=true, session=Session}=State) -> 
    reply({ok, maps:get(answer, Session)}, State);

handle_call(get_answer, From, #state{wait_answer=Wait}=State) -> 
    noreply(State#state{wait_answer=[From|Wait]});

handle_call(get_state, _From, State) -> 
    reply(State, State);

handle_call(Msg, From, State) -> 
    handle(nkmedia_session_handle_call, [Msg, From], State).


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast(do_start, State) ->
    do_start(State);

handle_cast({set_answer, Answer}, State) ->
    case do_set_answer(Answer, State) of
        {ok, State2} ->
            noreply(State2);
        {error, Error, State2} ->
            ?LLOG(notice, "set_answer error: ~p", [Error], State2),
            do_stop(Error, State2)
    end;

handle_cast({set_slave_answer, SlaveId, Answer}, #state{session=Session}=State) ->
    case Session of
        #{slave_peer:=SlaveId} ->
            case handle(nkmedia_session_slave_answer, [Answer], State) of
                {ok, Answer2, State2} ->
                    handle_cast({set_answer, Answer2}, State2);
                {ignore, State2} ->
                    {noreply, State2}
            end;
        _ ->
            ?LLOG(notice, "received answer from unknown slave ~s", [SlaveId], State),
            noreply(State)
    end;

handle_cast({set_type, Type, TypeExt}, #state{session=Session}=State) ->
    Session2 = ?SESSION(#{type=>Type, type_ext=>TypeExt}, Session),
    {ok, #state{}=State2} = check_type(State#state{session=Session2}),
    noreply(State2);

handle_cast({cmd, Cmd, Opts}, State) ->
    {_Reply, State2} = do_cmd(Cmd, Opts, State),
    noreply(State2);

handle_cast({info, Info}, State) ->
    noreply(event({info, Info}, State));

handle_cast({candidate, #candidate{type=offer}=Candidate}, State) ->
    noreply(do_offer_candidate(Candidate, State));

handle_cast({candidate, #candidate{type=answer}=Candidate}, State) ->
    noreply(do_answer_candidate(Candidate, State));

% We assume that if a candidate has no type, it is from the client (not the backend)
handle_cast({candidate, Candidate}, #state{backend_role=offeree}=State) ->
    handle_cast({candidate, Candidate#candidate{type=offer}}, State);

handle_cast({candidate, Candidate}, #state{backend_role=offerer}=State) ->
    handle_cast({candidate, Candidate#candidate{type=answer}}, State);

handle_cast({peer_candidate, PeerId, Candidate}, #state{session=Session}=State) ->
    case 
        {ok, PeerId} == maps:find(slave_peer, Session) orelse 
        {ok, PeerId} == maps:get(master_peer, Session)
    of
        true ->
            case handle(nkmedia_session_peer_candidate, [Candidate], State) of
                {ok, Candidate2, State2} ->
                    handle_cast({candidate, Candidate2}, State2);
                {ignore, State2} ->
                    noreply(State2)
            end;
        false ->
            ?LLOG(notice, "received candidate from unknown peer ~s", [PeerId], State),
            noreply(State)
    end;


% handle_cast({candidate, Candidate}, #state{role=offerer}=State) ->
%     % We sent the offer, so this client candidate must be for the answer
%     noreply(do_answer_candidate(Candidate, State));

% handle_cast({candidate, Candidate}, #state{role=offeree}=State) ->
%     % We had an offer and must make the answer, so this client candidate 
%     % must be for the offer
%     noreply(do_offer_candidate(Candidate, State));

% handle_cast({backend_candidate, Candidate}, #state{role=offerer}=State) ->
%     % We sent the offer, so this backend candidate must be for the offer
%     noreply(do_offer_candidate(Candidate, State));

% handle_cast({backend_candidate, Candidate}, #state{role=offeree}=State) ->
%     % We had an offer and must make the answer, so this backend candidate 
%     % must be for the answer
%     noreply(do_answer_candidate(Candidate, State));

handle_cast({link_to_master, MasterId, PidB}, State) ->
    % We are Slave of MasterId
    ?LLOG(info, "linked to master ~s", [MasterId], State),
    State2 = links_add({master_peer, MasterId}, PidB, State),
    State3 = add_to_session(master_peer, MasterId, State2),
    noreply(State3);

handle_cast({unlink_session, PeerId}, #state{id=SessId, session=Session}=State) ->
    case maps:find(slave_peer, Session) of
        {ok, PeerId} ->
            % We are Master of SlaveId
            do_cast(self(), {unlink_from_slave, PeerId}),
            do_cast(PeerId, {unlink_from_master, SessId});
        _ ->
            ok
    end,
    case maps:find(master_peer, Session) of
        {ok, PeerId} ->
            % We are Slave of PeerId
            do_cast(self(), {unlink_from_master, PeerId}),
            do_cast(PeerId, {unlink_from_slave, SessId});
        _ ->
            ok
    end,
    noreply(State);

handle_cast(unlink_session, #state{id=SessId, session=Session}=State) ->
    case maps:find(slave_peer, Session) of
        {ok, SlaveId} ->
            % We are Master of SlaveId
            do_cast(self(), {unlink_from_slave, SlaveId}),
            do_cast(SlaveId, {unlink_from_master, SessId});
        error ->
            ok
    end,
    case maps:find(master_peer, Session) of
        {ok, MasterId} ->
            % We are Slave of MasterId
            do_cast(self(), {unlink_from_master, MasterId}),
            do_cast(MasterId, {unlink_from_slave, SessId});
        error ->
            ok
    end,
    noreply(State);

handle_cast({unlink_from_slave, SlaveId}, #state{session=Session}=State) ->
    case maps:find(slave_peer, Session) of
        {ok, SlaveId} ->
            ?LLOG(notice, "unlinked from slave ~s", [SlaveId], State),
            State2 = links_remove({slave_peer, SlaveId}, State),
            noreply(remove_from_session(slave_peer, State2));
        _ ->
            noreply(State)
    end;

handle_cast({unlink_from_master, MasterId}, #state{session=Session}=State) ->
    case maps:find(master_peer, Session) of
        {ok, MasterId} ->
            ?LLOG(notice, "unlinked from master ~s", [MasterId], State),
            State2 = links_remove({master_peer, MasterId}, State),
            noreply(remove_from_session(master_peer, State2));
        _ ->
            noreply(State)
    end;

handle_cast({register, Link}, State) ->
    ?LLOG(info, "registered link (~p)", [Link], State),
    noreply(links_add(Link, State));

handle_cast({unregister, Link}, State) ->
    ?LLOG(info, "proc unregistered (~p)", [Link], State),
    noreply(links_remove(Link, State));

handle_cast({stop, Error}, State) ->
    do_stop(Error, State);

handle_cast(Msg, State) -> 
    handle(nkmedia_session_handle_cast, [Msg], State).


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({timeout, _, session_timeout}, State) ->
    ?LLOG(notice, "operation timeout", [], State),
    do_stop(session_timeout, State);

handle_info({timeout, _, offer_ice_timeout}, State) ->
    ?LLOG(info, "Offer ICE timeout", [], State),
    noreply(do_offer_candidate(#candidate{last=true}, State));

handle_info({timeout, _, answer_ice_timeout}, State) ->
    ?LLOG(info, "Answer ICE timeout", [], State),
    noreply(do_answer_candidate(#candidate{last=true}, State));

handle_info({'DOWN', Ref, process, _Pid, Reason}=Msg, #state{id=Id}=State) ->
    case links_down(Ref, State) of
        {ok, Link, State2} ->
            case handle(nkmedia_session_reg_down, [Id, Link, Reason], State2) of
                {ok, State3} ->
                    noreply(State3);
                {stop, normal, State3} ->
                    do_stop(normal, State3);    
                {stop, Error, State3} ->
                    ?LLOG(notice, "stopping beacuse of reg '~p' down (~p)",
                          [Link, Reason], State3),
                    do_stop(Error, State3)
            end;
        not_found ->
            handle(nkmedia_session_handle_info, [Msg], State)
    end;
    
handle_info(Msg, State) -> 
    handle(nkmedia_session_handle_info, [Msg], State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(OldVsn, State, Extra) ->
    nklib_gen_server:code_change(nkmedia_session_code_change, 
                                 OldVsn, State, Extra, 
                                 #state.srv_id, #state.session).

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    case Reason of
        normal ->
            ?LLOG(info, "terminate: ~p", [Reason], State),
            _ = do_stop(normal, State);
        _ ->
            ?LLOG(notice, "terminate: ~p", [Reason], State),
            _ = do_stop(anormal_termination, State)
    end,
    {ok, _State2} = handle(nkmedia_session_terminate, [Reason], State).




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_start(#state{type=Type, backend_role=Role, session=Session}=State) ->
    ?LLOG(notice, "session start: ~p, ~p", [Role, maps:remove(offer, Session)], State),
    case handle(nkmedia_session_start, [Type], State) of
        {ok, State2} ->
            case check_offer(State2) of
                {ok, State3} ->
                    noreply(restart_timer(State3));
                {error, Error, State3} ->
                    ?LLOG(notice, "do_start error: ~p", [Error], State3),
                    do_stop(Error, State3)
            end;
       {error, Error, State2} ->
            ?LLOG(notice, "do_start error: ~p", [Error], State2),
            do_stop(Error, State2)
    end.


%% @private
do_cmd(Cmd, Opts, State) ->
    case handle(nkmedia_session_cmd, [Cmd, Opts], State) of
        {ok, Reply, State2} -> 
            {{ok, Reply}, State2};
        {error, Error, State2} ->
            {{error, Error}, State2}
    end.



%% @private
check_offer(#state{has_offer=false, session=#{offer:=Offer}}=State) ->
    % The callback can update the answer and type here also
    case do_set_offer(Offer, State) of
        {ok, State2} -> 
            check_answer(State2);
        {error, Error, State2} -> 
            {error, Error, State2}
    end;

check_offer(State) ->
    check_answer(State).


%% @private
check_answer(#state{has_answer=false, session=#{answer:=Answer}}=State) ->
    % The callback can update the type here also
    case do_set_answer(Answer, State) of
        {ok, State2} -> 
            check_type(State2);
        {error, Error, State2} -> 
            {error, Error, State2}
    end;

check_answer(State) ->
    check_type(State).


%% @private
check_type(#state{type=OldType, type_ext=OldExt, session=Session}=State) ->
    case Session of
        #{type:=OldType, type_ext:=OldExt} ->
            {ok, State};
        #{type:=Type, type_ext:=Ext} ->
            State2 = State#state{type=Type, type_ext=Ext},
            ?LLOG(info, "session updated (~p)", [Ext], State2),
            {ok, event({session_type, Type, Ext}, State2)}
    end.


%% @private
do_set_offer(_Offer, #state{has_offer=true}=State) ->
    {error, offer_already_set, State};

do_set_offer(Offer, #state{type=Type, session=Session}=State) ->
    NoTrickleIce = maps:get(no_offer_trickle_ice, Session, false),
    case Offer of
        #{trickle_ice:=true} when NoTrickleIce ->
            #state{offer_candidates=trickle} = State,
            Time = maps:get(max_ice_time, Session, ?MAX_ICE_TIME),
            erlang:start_timer(Time, self(), offer_ice_timeout),
            ?LLOG(notice, "starting buffering offer Trickle ICE", [], State),
            Session2 = ?SESSION(#{offer=>Offer}, Session),
            {ok, State#state{session=Session2, offer_candidates=[]}};
        _ ->
            case handle(nkmedia_session_offer, [Type, Offer], State) of
                {ok, Offer2, State2} ->
                    #state{wait_offer=Wait, session=Session2} = State2,
                    reply_all_waiting({ok, Offer2}, Wait),
                    State3 = State2#state{
                        has_offer = true, 
                        session = ?SESSION(#{offer=>Offer}, Session2),
                        wait_offer = []
                    },
                    ?LLOG(info, "offer set", [], State3),
                    % ?LLOG(info, "offer:\n~s", [maps:get(sdp, Offer2, <<>>)], State3),
                    {ok, State3};
                {ignore, State2} ->
                    {ok, State2};
                {error, Error, State2} ->
                    {error, Error, State2}
            end
    end.


%% @private
do_set_answer(_Answer, #state{has_offer=false}=State) ->
    {error, offer_not_set, State};

do_set_answer(_Answer, #state{has_answer=true}=State) ->
    {error, answer_already_set, State};

do_set_answer(Answer, #state{type=Type, session=Session}=State) ->
    NoTrickleIce = maps:get(no_answer_trickle_ice, Session, false),
    case Answer of
        #{trickle_ice:=true} when NoTrickleIce ->
            #state{answer_candidates=trickle} = State,
            Time = maps:get(max_ice_time, Session, ?MAX_ICE_TIME),
            erlang:start_timer(Time, self(), answer_ice_timeout),
            ?LLOG(notice, "starting buffering answer Trickle ICE", [], State),
            Session2 = ?SESSION(#{answer=>Answer}, Session),
            {ok, State#state{session=Session2, answer_candidates=[]}};
        _ ->
            ?LLOG(warning, "set ans", [], State),
            case handle(nkmedia_session_answer, [Type, Answer], State) of
                {ok, Answer2, State2} ->
                    #state{wait_answer=Wait, session=Session2} = State2,
                    reply_all_waiting({ok, Answer2}, Wait),
                    State3 = State2#state{
                        has_answer = true, 
                        session = ?SESSION(#{answer=>Answer2}, Session2),
                        wait_answer = []
                    },
                    ?LLOG(info, "answer set", [], State3),
                    % ?LLOG(info, "answer:\n~s", [maps:get(sdp, Answer2, <<>>)], State3),
                    case Session of
                        #{master_peer:=MasterId, session_id:=Id} ->
                            ?LLOG(notice, "calling set_slave_answer for ~s", 
                                  [MasterId], State),
                            set_slave_answer(MasterId, Id, Answer2);
                        _ ->
                            ok
                    end,
                    {ok, event({answer, Answer2}, restart_timer(State3))};
                {ignore, State2} ->
                    {ok, State2};
                {error, Error, State2} ->
                    {error, Error, State2}
            end
    end.



%% @private
do_offer_candidate(Candidate, 
                   #state{offer_candidates=trickle, backend_role=offerer}=State) ->
    % We are not storing candidates (we are using Trickle ICE)
    % The backend made the offer, so this offer candidate is from the backend and 
    % must be announced to the client or peer session
    case State of
        #state{session=#{slave_peer:=SlaveId, session_id:=Id}} ->
            peer_candidate(SlaveId, Id, Candidate),
            State;
        _ ->
            event({candidate, Candidate}, State)
    end;

do_offer_candidate(Candidate, 
                   #state{offer_candidates=trickle, backend_role=offeree}=State) ->
    % The backend made the answer, so this offer candidate is from the client 
    % to the backend
    % (or for my p2p peer, that is my 'backend')
    case State of
        #state{session=#{backend:=p2p, slave_peer:=SlaveId, session_id:=Id}} ->
            peer_candidate(SlaveId, Id, Candidate),
            State;
        _ ->
            % Send the candidate to the backend
            case handle(nkmedia_session_candidate, [Candidate], State) of
                {ok, State2} ->
                    State2;
                {continue, State2} ->
                    ?LLOG(notice, "unmanaged offer candidate!", [], State2),
                    State2
            end
    end;

do_offer_candidate(#candidate{last=true}, #state{offer_candidates=last}=State) ->
    State;

do_offer_candidate(#candidate{last=true}, #state{offer_candidates=[]}=State) ->
    ?LLOG(warning, "no received offer candidates!", [], State),
    stop(self(), no_ice_candidates),
    State;

do_offer_candidate(Candidate, #state{offer_candidates=last}=State) ->
    ?LLOG(notice, "ignoring late offer candidate", [Candidate], State),
    State;

do_offer_candidate(#candidate{last=true}, State) ->
    #state{offer_candidates=Candidates, session=Session} = State,
    #{offer:=#{sdp:=SDP1}=Offer} = Session,
    SDP2 = nksip_sdp_util:add_candidates(SDP1, Candidates),
    Offer2 = Offer#{sdp:=nksip_sdp:unparse(SDP2), trickle_ice=>false},
    State2 = State#state{
        session = ?SESSION(#{offer=>Offer2}, Session), 
        offer_candidates = last
    },
    ?LLOG(notice, "last offer candidate received", [], State),
    case check_offer(State2) of
        {ok, State3} ->
            State3;
        {error, Error, State3} ->
            ?LLOG(notice, "ICE error after last candidate: ~p", [Error], State),
            stop(self(), Error)
    end,
    State3;

do_offer_candidate(Candidate, #state{offer_candidates=Candidates}=State) ->
    Candidates2 = [Candidate|Candidates],
    State#state{offer_candidates=Candidates2}.


%% @private
do_answer_candidate(Candidate, 
                    #state{answer_candidates=trickle, backend_role=offerer}=State) ->
    % We are not storing candidates (we are using Tricle ICE)
    % The backend made the offer, so this answer candidate is from the client 
    % to the backend
    % (or for my p2p peer, that is my 'backend')
    case State of
        #state{session=#{backend:=p2p, master_peer:=MasterId, session_id:=Id}} ->
            peer_candidate(MasterId, Id, Candidate),
            State;
        _ ->
            % Send the candidate to the backend
            case handle(nkmedia_session_candidate, [Candidate], State) of
                {ok, State2} ->
                    State2;
                {continue, State2} ->
                    ?LLOG(notice, "unmanaged answer candidate!", [], State2),
                    State2
            end
    end;

do_answer_candidate(Candidate, 
                    #state{answer_candidates=trickle, backend_role=offeree}=State) ->
    % The backend made the answer, so this answer candidate is from the backend,
    % so it must be announced to the client (or my peer session)
    case State of
        #state{session=#{master_peer:=MasterId, session_id:=Id}} ->
            peer_candidate(MasterId, Id, Candidate),
            State;
        _ ->
            event({candidate, Candidate}, State)
    end;

do_answer_candidate(#candidate{last=true}, #state{answer_candidates=last}=State) ->
    State;

do_answer_candidate(Candidate, #state{answer_candidates=last}=State) ->
    ?LLOG(notice, "ignoring late answer candidate ~p", [Candidate], State),
    State;

do_answer_candidate(#candidate{last=true}, #state{answer_candidates=[]}=State) ->
    ?LLOG(warning, "no received answer candidates!", [], State),
    stop(self(), no_ice_candidates),
    State;

do_answer_candidate(#candidate{last=true}, State) ->
    #state{answer_candidates=Candidates, session=Session} = State,
    #{answer:=#{sdp:=SDP1}=Answer} = Session,
    SDP2 = nksip_sdp_util:add_candidates(SDP1, Candidates),
    Answer2 = Answer#{sdp:=nksip_sdp:unparse(SDP2), trickle_ice=>false},
    State2 = State#state{
        session = ?SESSION(#{answer=>Answer2}, Session), 
        answer_candidates = last
    },
    ?LLOG(notice, "last answer candidate received", [], State),
    case check_answer(State2) of
        {ok, State3} ->
            State3;
        {error, Error, State3} ->
            ?LLOG(notice, "ICE error after last candidate: ~p", [Error], State),
            stop(self(), Error)
    end,
    State3;

do_answer_candidate(Candidate, #state{answer_candidates=Candidates}=State) ->
    Candidates2 = [Candidate|Candidates],
    State#state{answer_candidates=Candidates2}.




%% ===================================================================
%% Util
%% ===================================================================


%% @private
restart_timer(State) ->
    #state{
        timer = Timer, 
        session = Session, 
        has_answer = HasAnswer
    } = State,
    nklib_util:cancel_timer(Timer),
    Time = case HasAnswer of
        true -> maps:get(ready_timeout, Session, ?DEF_READY_TIMEOUT);
        false -> maps:get(wait_timeout, Session, ?DEF_WAIT_TIMEOUT)
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), session_timeout),
    State#state{timer=NewTimer}.


%% @private
reply(Reply, State) ->
    {reply, Reply, State}.


%% @private
reply_all_waiting(Msg, List) ->
    lists:foreach(fun(From) -> nklib_util:reply(From, Msg) end, List).


% %% @private
% reply(Reply, From, State) ->
%     nklib_util:reply(From, Reply),
%     noreply(State).


%% @private
noreply(State) ->
    {noreply, State}.


%% @private
do_stop(_Reason, #state{stop_sent=true}=State) ->
    {stop, normal, State};

do_stop(Reason, #state{session=Session}=State) ->
    {ok, State2} = handle(nkmedia_session_stop, [Reason], State),
    State3 = event({stop, Reason}, State2#state{stop_sent=true}),
    case Session of
        #{master_peer:=MasterId} -> stop(MasterId, peer_stopped);
        _ -> ok
    end,
    case Session of
        #{slave_peer:=SlaveId} -> stop(SlaveId, peer_stopped);
        _ -> ok
    end,
    % Allow events to be processed
    timer:sleep(100),
    {stop, normal, State3}.


%% @private
event(Event, #state{id=Id}=State) ->
    case Event of
        {offer, _} ->  ?LLOG(info, "sending 'offer'", [], State);
        {answer, _} -> ?LLOG(info, "sending 'answer'", [], State);
        _ ->           ?LLOG(info, "sending 'event': ~p", [Event], State)
    end,
    State2 = links_fold(
        fun(Link, AccState) ->
            {ok, AccState2} = 
                handle(nkmedia_session_reg_event, [Id, Link, Event], AccState),
                AccState2
        end,
        State,
        State),
    {ok, State3} = handle(nkmedia_session_event, [Id, Event], State2),
    State3.


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.session).


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(SessId) ->
    case nklib_proc:values({?MODULE, SessId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(SessId, Msg) ->
    do_call(SessId, Msg, ?DEF_SYNC_TIMEOUT).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> nkservice_util:call(Pid, Msg, Timeout);
        not_found -> {error, session_not_found}
    end.


%% @private
do_cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, session_not_found}
    end.


%% @private
do_info(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> Pid ! Msg;
        not_found -> {error, session_not_found}
    end.


%% @private
add_to_session(Key, Val, #state{session=Session}=State) ->
    Session2 = maps:put(Key, Val, Session),
    State#state{session=Session2}.

remove_from_session(Key, #state{session=Session}=State) ->
    Session2 = map:remove(Key, Session),
    State#state{session=Session2}.



%% @private
links_add(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Links)}.


%% @private
links_add(Link, Pid, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, none, Pid, Links)}.


%% @private
links_remove(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Link, Links)}.


%% @private
links_down(Mon, #state{links=Links}=State) ->
    case nklib_links:down(Mon, Links) of
        {ok, Link, _Data, Links2} -> 
            {ok, Link, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


%% @private
links_fold(Fun, Acc, #state{links=Links}) ->
    nklib_links:fold(Fun, Acc, Links).






