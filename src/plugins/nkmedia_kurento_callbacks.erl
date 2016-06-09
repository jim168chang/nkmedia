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

%% @doc Plugin implementing a Kurento server
-module(nkmedia_kurento_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_kurento_init/2, nkmedia_kurento_terminate/2,
         nkmedia_kurento_handle_call/3, nkmedia_kurento_handle_cast/2,
         nkmedia_kurento_handle_info/2]).

-define(KMS_WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia].


plugin_syntax() ->
    nkpacket:register_protocol(kurento, nkmedia_kurento),
    nkpacket:register_protocol(kurento_proxy, nkmedia_kms_proxy_server),
    #{
        kurento_listen => fun parse_listen/3,
        kurento_samples => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % kurento_listen will be already parsed
    Listen1 = maps:get(kurento_listen, Config, []),
    % With the 'user' parameter we tell nkmedia_kurento protocol
    % to use the service callback module, so it will find
    % nkmedia_kurento_* funs there.
    Opts1 = #{
        class => {nkmedia_kurento, SrvId},
        % get_headers => [<<"user-agent">>],
        idle_timeout => ?KMS_WS_TIMEOUT
    },                                  
    Listen2 = [{Conns, maps:merge(ConnOpts, Opts1)} || {Conns, ConnOpts} <- Listen1],
    Web1 = maps:get(kurento_samples, Config, []),
    Path1 = list_to_binary(code:priv_dir(nkmedia)),
    Path2 = <<Path1/binary, "/www/kurento_samples">>,
    Opts2 = #{
        class => {nkmedia_kurento_samples, SrvId},
        http_proto => {static, #{path=>Path2, index_file=><<"index.html">>}}
    },
    Web2 = [{Conns, maps:merge(ConnOpts, Opts2)} || {Conns, ConnOpts} <- Web1],
    Listen2 ++ Web2.


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Kurento (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA Kurento (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering Callbacks
%% ===================================================================

-type kurento() :: nkmedia_kurento:kurento().


%% @doc Called when a new kurento connection arrives
-spec nkmedia_kurento_init(nkpacket:nkport(), kurento()) ->
    {ok, kurento()}.

nkmedia_kurento_init(_NkPort, Verto) ->
    {ok, Verto}.


%% @doc Called when the connection is stopped
-spec nkmedia_kurento_terminate(Reason::term(), kurento()) ->
    {ok, kurento()}.

nkmedia_kurento_terminate(_Reason, Verto) ->
    {ok, Verto}.


%% @doc 
-spec nkmedia_kurento_handle_call(Msg::term(), {pid(), term()}, kurento()) ->
    {ok, kurento()} | continue().

nkmedia_kurento_handle_call(Msg, _From, Verto) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_kurento_handle_cast(Msg::term(), kurento()) ->
    {ok, kurento()}.

nkmedia_kurento_handle_cast(Msg, Verto) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, Verto}.


%% @doc 
-spec nkmedia_kurento_handle_info(Msg::term(), kurento()) ->
    {ok, Verto::map()}.

nkmedia_kurento_handle_info(Msg, Verto) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, Verto}.




%% ===================================================================
%% Implemented Callbacks - nkmedia_session
%% ===================================================================






%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(Key, Url, _Ctx) ->
    Schemes = case Key of
        kurento_listen -> [kurento, kurento_proxy];
        kurento_samples -> [https]
    end,
    Opts = #{valid_schemes=>Schemes, resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





