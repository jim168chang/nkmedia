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

%% @doc Room Plugin API
-module(nkmedia_room_api_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/3]).

-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Events
%% ===================================================================


%% @private
-spec event(nkmedia_room:id(), nkmedia_room:event(), nkmedia_room:room()) ->
    ok.

event(RoomId, created, Room) ->
    Data = nkmedia_room_api_syntax:get_info(Room),
    send_event(RoomId, created, Data, Room);

event(RoomId, {started_member, SessId, Info}, Room) ->
    send_event(RoomId, started_member, Info#{session_id=>SessId}, Room);

event(RoomId, {stopped_member, SessId, Info}, Room) ->
    send_event(RoomId, stopped_member, Info#{session_id=>SessId}, Room);

event(SessId, {status, Update}, Session) ->
    send_event(SessId, status, Update, Session);

event(RoomId, {info, Info, Meta}, Room) ->
    send_event(RoomId, info, Meta#{info=>Info}, Room);

%% 'destroyed' is an internal event only
event(RoomId, {stopped, Reason}, #{srv_id:=SrvId}=Room) ->
    {Code, Txt} = nkservice_util:error_code(SrvId, Reason),
    send_event(RoomId, destroyed, #{code=>Code, reason=>Txt}, Room);

event(_RoomId, _Event, _Room) ->
    ok.

%% ===================================================================
%% Internal
%% ===================================================================


%% @private
send_event(RoomId, Type, Body, #{srv_id:=SrvId}) ->
    Event = #event{
        srv_id = SrvId,     
        class = <<"media">>, 
        subclass = <<"room">>,
        type = nklib_util:to_binary(Type),
        obj_id = RoomId,
        body = Body
    },
    nkservice_events:send(Event),
    ok.

