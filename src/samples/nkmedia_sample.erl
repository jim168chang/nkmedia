
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

%% @doc Plugins implementing a Verto-compatible server
-module(nkmedia_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0, restart/0]).
-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nkmedia_verto_login/4, nkmedia_verto_call/3]).
-export([nkmedia_call_resolve/2]).
-export([nkmedia_janus_call/3]).
% -export([nkmedia_call_event/3, nkmedia_session_event/3]).
-export([sip_register/2]).

-include("nkmedia.hrl").

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("Sample (~s) "++Txt, [maps:get(user, State) | Args])).



%% ===================================================================
%% Public
%% ===================================================================


start() ->
    _CertDir = code:priv_dir(nkpacket),
    Spec = #{
        plugins => [?MODULE, nksip_registrar, nksip_trace],
        verto_listen => "verto:all:8082",
        % verto_listen => "verto_proxy:all:8082",
        verto_communicator => "https:all:8082/vc",
        % janus_listen => "janus_proxy:all:8989",
        janus_listen => "janus:all:8989",
        janus_demos => "https://all:8083/janus",
        log_level => debug,
        nksip_trace => {console, all},
        sip_listen => <<"sip:all:5060">>,
        log_level => debug
    },
    nkservice:start(sample, Spec).


stop() ->
    nkservice:stop(sample).

restart() ->
    stop(),
    timer:sleep(100),
    start().



%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia, nkmedia_sip, nkmedia_verto, nkmedia_janus_proto].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~s) starting", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin ~p (~p) stopping", [?MODULE, Name]),
    {ok, Config}.




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================


nkmedia_verto_login(VertoId, Login, Pass, Verto) ->
    case binary:split(Login, <<"@">>) of
        [User, _] ->
            Verto2 = Verto#{user=>User},
            ?LOG_SAMPLE(info, "login: ~s (pass ~s, ~s)", [User, Pass, VertoId], Verto2),
            {true, User, Verto2};
        _ ->
            {false, Verto}
    end.


nkmedia_verto_call(SessId, Dest, Verto) ->
    case send_call(SessId, Dest) of
        ok ->
            {ok, Verto};
        no_number ->
            {hangup, "No Number", Verto} 
    end.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================


nkmedia_janus_call(SessId, Dest, Janus) ->
    case send_call(SessId, Dest) of
        ok ->
            {ok, Janus};
        no_number ->
            {hangup, "No Number", Janus} 
    end.



%% ===================================================================
%% nkmedia callbacks
%% ===================================================================

%% @private
nkmedia_call_resolve(Dest, Call) ->
    {continue, [Dest, Call]}.



%% ===================================================================
%% sip_callbacks
%% ===================================================================

sip_register(Req, Call) ->
    Req2 = nksip_registrar_util:force_domain(Req, <<"nkmedia_sample">>),
    {continue, [Req2, Call]}.




%% ===================================================================
%% Internal
%% ===================================================================

send_call(SessId, Dest) ->
    case Dest of 
        <<"e">> ->
            ok = nkmedia_session:set_answer(SessId, echo, #{});
        <<"fe">> ->
            ok = nkmedia_session:set_answer(SessId, echo, #{type=>pbx});
        <<"m1">> ->
            ok = nkmedia_session:set_answer(SessId, {mcu, "mcu1"}, #{});
        <<"m2">> ->
            ok = nkmedia_session:set_answer(SessId, {mcu, "mcu2"}, #{});
        <<"p">> ->
            ok = nkmedia_session:set_answer(SessId, {publisher, 1234}, #{});
        <<"d", Num/binary>> ->
            ok = nkmedia_session:set_answer(SessId, {call, Num}, #{type=>p2p});
        <<"f", Num/binary>> -> 
            ok = nkmedia_session:set_answer(SessId, {call, Num}, #{type=>pbx});
        <<"j", Num/binary>> ->
            ok = nkmedia_session:set_answer(SessId, {call, Num}, #{type=>proxy});
        _ ->
            no_number
    end.



