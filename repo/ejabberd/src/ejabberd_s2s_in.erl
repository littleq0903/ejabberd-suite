%%%----------------------------------------------------------------------
%%% File    : ejabberd_s2s_in.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Serve incoming s2s connection
%%% Created :  6 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2012   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_s2s_in).
-author('alexey@process-one.net').

-behaviour(p1_fsm).

%% External exports
-export([start/2,
	 start_link/2,
	 match_domain/2,
	 socket_type/0]).

%% gen_fsm callbacks
-export([init/1,
	 wait_for_stream/2,
	 wait_for_feature_request/2,
	 stream_established/2,
	 handle_event/3,
	 handle_sync_event/4,
	 code_change/4,
	 handle_info/3,
	 print_state/1,
	 terminate/3]).

-include_lib("exmpp/include/exmpp.hrl").

-include("ejabberd.hrl").
-include("XmppAddr.hrl").
-include_lib("public_key/include/public_key.hrl"). 
-define(PKIXEXPLICIT, 'OTP-PUB-KEY').
-define(PKIXIMPLICIT, 'OTP-PUB-KEY').

-define(DICT, dict).

-record(state, {socket,
		sockmod,
		streamid,
		shaper,
		tls = false,
		tls_enabled = false,
		tls_required = false,
		tls_certverify = false,
		tls_options = [],
		server,
		authenticated = false,
		auth_domain,
	        connections = ?DICT:new(),
		timer}).


%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

-define(FSMLIMITS, [{max_queue, 2000}]). %% if queue grows more than this, we shutdown this connection.

%% Module start with or without supervisor:
-ifdef(NO_TRANSIENT_SUPERVISORS).
-define(SUPERVISOR_START, p1_fsm:start(ejabberd_s2s_in, [SockData, Opts],
					?FSMOPTS ++ ?FSMLIMITS)).
-else.
-define(SUPERVISOR_START, supervisor:start_child(ejabberd_s2s_in_sup,
						 [SockData, Opts])).
-endif.

% These are the namespace already declared by the stream opening. This is
% used at serialization time.
-define(DEFAULT_NS, ?NS_JABBER_SERVER).
-define(PREFIXED_NS,
        [{?NS_XMPP, ?NS_XMPP_pfx}, {?NS_DIALBACK, ?NS_DIALBACK_pfx}]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(SockData, Opts) ->
    ?SUPERVISOR_START.

start_link(SockData, Opts) ->
    p1_fsm:start_link(ejabberd_s2s_in, [SockData, Opts], ?FSMOPTS ++ ?FSMLIMITS).

socket_type() ->
    xml_stream.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([{SockMod, Socket}, Opts]) ->
    ?DEBUG("started: ~p", [{SockMod, Socket}]),
    Shaper = case lists:keysearch(shaper, 1, Opts) of
		 {value, {_, S}} -> S;
		 _ -> none
	     end,
    {StartTLS, TLSRequired, TLSCertverify} = case ejabberd_config:get_local_option(s2s_use_starttls) of
             UseTls when (UseTls==undefined) or (UseTls==false) ->
                 {false, false, false};
             UseTls when (UseTls==true) or (UseTls==optional) ->
                 {true, false, false};
             required ->
                 {true, true, false};
             required_trusted ->
                 {true, true, true}
         end,
    TLSOpts = case ejabberd_config:get_local_option(s2s_certfile) of
		  undefined ->
		      [];
		  CertFile ->
		      [{certfile, CertFile}]
	      end,
    Timer = erlang:start_timer(?S2STIMEOUT, self(), []),
    {ok, wait_for_stream,
     #state{socket = Socket,
	    sockmod = SockMod,
	    streamid = new_id(),
	    shaper = Shaper,
	    tls = StartTLS,
	    tls_enabled = false,
	    tls_required = TLSRequired,
	    tls_certverify = TLSCertverify,
	    tls_options = TLSOpts,
	    timer = Timer}}.

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------

wait_for_stream({xmlstreamstart, Opening}, StateData) ->
    case {exmpp_stream:get_default_ns(Opening),
	  exmpp_xml:is_ns_declared_here(Opening, ?NS_DIALBACK),
	  exmpp_stream:get_receiving_entity(Opening),
	  exmpp_stream:get_version(Opening) == {1, 0}} of
	{?NS_JABBER_SERVER, _, Server, true} when
	      StateData#state.tls and (not StateData#state.authenticated) ->
	    Opening_Reply = exmpp_stream:opening_reply(Opening,
	      StateData#state.streamid),
	    send_element(StateData,
	      exmpp_stream:set_dialback_support(Opening_Reply)),
	    SASL =
		if
		    StateData#state.tls_enabled ->
			case (StateData#state.sockmod):get_peer_certificate(
			       StateData#state.socket) of
			    {ok, Cert} ->
				case (StateData#state.sockmod):get_verify_result(StateData#state.socket) of
				    0 ->
					[exmpp_server_sasl:feature(
					    ["EXTERNAL"])];
				    CertVerifyRes ->
					case StateData#state.tls_certverify of
					    true -> {error_cert_verif, CertVerifyRes, Cert};
					    false -> []
					end
				end;
			    error ->
				[]
			end;
		    true ->
			[]
		end,
	    StartTLS = if
			   StateData#state.tls_enabled ->
			       [];
			   (not StateData#state.tls_enabled) ->
			       [exmpp_server_tls:feature(StateData#state.tls_required)]
		       end,
	    case SASL of
		{error_cert_verif, CertVerifyResult, Certificate} ->
		    CertError = tls:get_cert_verify_string(CertVerifyResult, Certificate),
		    RemoteServer = exmpp_stream:get_initiating_entity(Opening),
		    ?INFO_MSG("Closing s2s connection: ~s <--> ~s (~s)", [StateData#state.server, RemoteServer, CertError]),
		    send_element(StateData, exmpp_stream:error('policy-violation', {"en", CertError})),
		    {atomic, Pid} = ejabberd_s2s:find_connection(exmpp_jid:make(Server), exmpp_jid:make(RemoteServer)),
		    ejabberd_s2s_out:stop_connection(Pid),
		    {stop, normal, StateData};
		_ ->
			Features = SASL ++ StartTLS ++ ejabberd_hooks:run_fold(
							 c2s_stream_features,
							 Server,
							 [], [Server]),
			send_element(StateData, exmpp_stream:features(Features)),
			{next_state, wait_for_feature_request, StateData#state{server = Server}}
	    end;
	{?NS_JABBER_SERVER, _, Server, true} when
	      StateData#state.authenticated ->
	    Opening_Reply = exmpp_stream:opening_reply(Opening,
	      StateData#state.streamid),
	    send_element(StateData,
	      exmpp_stream:set_dialback_support(Opening_Reply)),
	    Features = ejabberd_hooks:run_fold(
			 c2s_stream_features,
			 Server,
			 [], [Server]),
	    send_element(StateData, exmpp_stream:features(Features)),
	    {next_state, stream_established, StateData};
	{?NS_JABBER_SERVER, true, _Server, _} ->
            #xmlel{attrs = Attrs} = Opening,
            New_Attrs = exmpp_xml:remove_attribute_from_list(
                          Attrs, <<"version">>),
            Opening_Reply = exmpp_stream:opening_reply(
                              Opening#xmlel{attrs = New_Attrs},
                              StateData#state.streamid),
	    send_element(StateData,
	      exmpp_stream:set_dialback_support(Opening_Reply)),
	    {next_state, stream_established, StateData};
	_ ->
	    send_element(StateData, exmpp_stream:error('invalid-namespace')),
	    {stop, normal, StateData}
    end;

wait_for_stream({xmlstreamerror, _}, StateData) ->
    Opening_Reply = exmpp_stream:opening_reply(undefined, ?NS_JABBER_SERVER,
      "", StateData#state.streamid),
    send_element(StateData, Opening_Reply),
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    {stop, normal, StateData};

wait_for_stream(timeout, StateData) ->
    {stop, normal, StateData};

wait_for_stream(closed, StateData) ->
    {stop, normal, StateData}.


wait_for_feature_request({xmlstreamelement, El}, StateData) ->
    TLS = StateData#state.tls,
    TLSEnabled = StateData#state.tls_enabled,
    SockMod = (StateData#state.sockmod):get_sockmod(StateData#state.socket),
    case El of
	#xmlel{ns = ?NS_TLS, name = 'starttls'} when TLS == true,
				   TLSEnabled == false,
				   SockMod == gen_tcp ->
	    ?DEBUG("starttls", []),
	    Socket = StateData#state.socket,
	    Proceed = exmpp_xml:node_to_list(
	      exmpp_server_tls:proceed(), [?DEFAULT_NS], ?PREFIXED_NS),
	    TLSOpts = case ejabberd_config:get_local_option(
			     {domain_certfile,
			      StateData#state.server}) of
			  undefined ->
			      StateData#state.tls_options;
			  CertFile ->
			      [{certfile, CertFile} |
			       lists:keydelete(
				 certfile, 1,
				 StateData#state.tls_options)]
		      end,
	    TLSSocket = (StateData#state.sockmod):starttls(
			  Socket, TLSOpts,
			  Proceed),
	    {next_state, wait_for_stream,
	     StateData#state{socket = TLSSocket,
			     streamid = new_id(),
			     tls_enabled = true,
			     tls_options = TLSOpts
			    }};
	#xmlel{ns = ?NS_SASL, name = 'auth'} when TLSEnabled ->
	    case exmpp_server_sasl:next_step(El) of
		{auth, "EXTERNAL", Auth} ->
		    {AuthDomain, AuthRes} = try
			AuthDomain0 = exmpp_stringprep:nameprep(Auth),
			AuthRes0 = case (StateData#state.sockmod):get_peer_certificate(
			       StateData#state.socket) of
			    {ok, Cert} ->
				case (StateData#state.sockmod):get_verify_result(
				       StateData#state.socket) of
				    0 ->
					case idna:domain_utf8_to_ascii(AuthDomain0) of
					    false ->
						false;
					    PCAuthDomain ->
						lists:any(
						  fun(D) ->
							  match_domain(
							    PCAuthDomain, D)
						  end, get_cert_domains(Cert))
					end;
				    _ ->
					false
				end;
			    error ->
                                {undefined, false}
			end,
			{AuthDomain0, AuthRes0}
		    catch
			_ ->
			    false
		    end,
		    AllowRemoteHost = ejabberd_s2s:allow_host("", AuthDomain),
		    if
			AuthRes andalso AllowRemoteHost ->
			    (StateData#state.sockmod):reset_stream(
			      StateData#state.socket),
			    send_element(StateData,
			      exmpp_server_sasl:success()),
			    ?DEBUG("(~w) Accepted s2s authentication for ~s",
				      [StateData#state.socket, AuthDomain]),
			  %% acess rules are first checked against the globally defined ones, that have precedence over 
			  %% domain-specific ones.. http://www.process-one.net/docs/ejabberd/guide_en.html#AccessRights
			  %% since there is allways a shaper defined globally for s2s, it doesn't matter the actual
			 %% local host, since the globall one will be used, even if this domain has a special rule
			    change_shaper(StateData, "", exmpp_jid:make(AuthDomain)),
			    {next_state, wait_for_stream,
			     StateData#state{streamid = new_id(),
					     authenticated = true,
					     auth_domain = AuthDomain
					    }};
			true ->
			    send_element(StateData,
			      exmpp_server_sasl:failure()),
			    send_element(StateData,
			      exmpp_stream:closing()),
			    {stop, normal, StateData}
		    end;
		_ ->
		    send_element(StateData,
		      exmpp_server_sasl:failure('invalid-mechanism')),
		    {stop, normal, StateData}
	    end;
	_ ->
	    stream_established({xmlstreamelement, El}, StateData)
    end;

wait_for_feature_request({xmlstreamend, _Name}, StateData) ->
    send_element(StateData, exmpp_stream:closing()),
    {stop, normal, StateData};

wait_for_feature_request({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    {stop, normal, StateData};

wait_for_feature_request(closed, StateData) ->
    {stop, normal, StateData}.


stream_established({xmlstreamelement, El}, StateData) ->
    cancel_timer(StateData#state.timer),
    Timer = erlang:start_timer(?S2STIMEOUT, self(), []),
    case is_key_packet(El) of
	{key, To, From, Id, Key} ->
	    ?DEBUG("GET KEY: ~p", [{To, From, Id, Key}]),
	    LTo = exmpp_stringprep:nameprep(To),
	    LFrom = exmpp_stringprep:nameprep(From),
	    %% Checks if the from domain is allowed and if the to
            %% domain is handled by this server:
            case {ejabberd_s2s:allow_host(LTo, LFrom),
                  lists:member(LTo, ejabberd_router:dirty_get_all_domains())} of
                {true, true} ->
		    ejabberd_s2s_out:terminate_if_waiting_delay(LTo, LFrom),
		    ejabberd_s2s_out:start(LTo, LFrom,
					   {verify, self(),
					    Key, StateData#state.streamid}),
		    Conns = ?DICT:store({LFrom, LTo}, wait_for_verification,
					StateData#state.connections),
		    change_shaper(StateData, LTo,
		      exmpp_jid:make(LFrom)),
		    {next_state,
		     stream_established,
		     StateData#state{connections = Conns,
				     timer = Timer}};
		{_, false} ->
		    send_element(StateData, exmpp_stream:error('host-unknown')),
		    {stop, normal, StateData};
                {false, _} ->
		    send_element(StateData, exmpp_stream:error('invalid-from')),
                    {stop, normal, StateData}
	    end;
	{verify, To, From, Id, Key} ->
	    ?DEBUG("VERIFY KEY: ~p", [{To, From, Id, Key}]),
	    LTo = exmpp_stringprep:nameprep(To),
	    LFrom = exmpp_stringprep:nameprep(From),
	    send_element(StateData, exmpp_dialback:verify_response(
		El, ejabberd_s2s:has_key({LTo, LFrom}, Key))),
	    {next_state, stream_established, StateData#state{timer = Timer}};
	_ ->
	    From = case exmpp_stanza:get_sender(El) of
		undefined ->
		    error;
		F ->
		    try
			exmpp_jid:parse(F)
		    catch
			_Exception1 -> error
		    end
	    end,
	    To = case exmpp_stanza:get_recipient(El) of
		undefined ->
		    error;
		T ->
		    try
			exmpp_jid:parse(T)
		    catch
			_Exception2 -> error
		    end
	    end,
	    % No namespace conversion (:server <-> :client) is done.
	    % This is handled by C2S and S2S send_element functions.
	    if
		(To /= error) and (From /= error) ->
		    LFrom = exmpp_jid:prep_domain_as_list(From),
		    LTo = exmpp_jid:prep_domain_as_list(To),
		    if
			StateData#state.authenticated ->
			    case (LFrom == StateData#state.auth_domain)
				andalso
				lists:member(
				  LTo,
				  ejabberd_router:dirty_get_all_domains()) of
				true ->
				    Name = El#xmlel.name,
				    if ((Name == 'iq') or
					(Name == 'message') or
					(Name == 'presence')) ->
					    ejabberd_hooks:run(
					      s2s_receive_packet,
					      exmpp_jid:prep_domain(To),
					      [From, To, El]),
					    ejabberd_router:route(
					      From, To, El);
				       true ->
					    error
				    end;
				false ->
				    error
			    end;
			true ->
			    case ?DICT:find({LFrom, LTo},
					    StateData#state.connections) of
				{ok, established} ->
				    Name = El#xmlel.name,
				    if ((Name == 'iq') or
					(Name == 'message') or
					(Name == 'presence')) ->
					    ejabberd_hooks:run(
					      s2s_receive_packet,
					      exmpp_jid:prep_domain(To),
					      [From, To, El]),
					    ejabberd_router:route(
					      From, To, El);
				       true ->
					    error
				    end;
				_ ->
				    error
			    end
		    end;
		true ->
		    error
	    end,
	    ejabberd_hooks:run(s2s_loop_debug, [{xmlstreamelement, El}]),
	    {next_state, stream_established, StateData#state{timer = Timer}}
    end;

stream_established({valid, From, To}, StateData) ->
    send_element(StateData, exmpp_dialback:validate(To, From)),
    LFrom = exmpp_stringprep:nameprep(From),
    LTo = exmpp_stringprep:nameprep(To),
    NSD = StateData#state{
	    connections = ?DICT:store({LFrom, LTo}, established,
				      StateData#state.connections)},
    {next_state, stream_established, NSD};

stream_established({invalid, From, To}, StateData) ->
    Valid = exmpp_dialback:validate(From, To),
    send_element(StateData, exmpp_stanza:set_type(Valid, "invalid")),
    LFrom = exmpp_stringprep:nameprep(From),
    LTo = exmpp_stringprep:nameprep(To),
    NSD = StateData#state{
	    connections = ?DICT:erase({LFrom, LTo},
				      StateData#state.connections)},
    {next_state, stream_established, NSD};

stream_established({xmlstreamend, _Name}, StateData) ->
    {stop, normal, StateData};

stream_established({xmlstreamerror, _}, StateData) ->
    send_element(StateData, exmpp_stream:error('xml-not-well-formed')),
    send_element(StateData, exmpp_stream:closing()),
    {stop, normal, StateData};

stream_established(timeout, StateData) ->
    {stop, normal, StateData};

stream_established(closed, StateData) ->
    {stop, normal, StateData}.



%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
%state_name(Event, From, StateData) ->
%    Reply = ok,
%    {reply, Reply, state_name, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.
%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: The associated StateData for this connection
%%   {reply, Reply, NextStateName, NextStateData}
%%   Reply = {state_infos, [{InfoName::atom(), InfoValue::any()]
%%----------------------------------------------------------------------
handle_sync_event(get_state_infos, _From, StateName, StateData) ->
    SockMod = StateData#state.sockmod,
    {Addr,Port} = try SockMod:peername(StateData#state.socket) of
		      {ok, {A,P}} ->  {A,P};
		      {error, _} -> {unknown,unknown}
		  catch
		      _:_ -> {unknown,unknown}
		  end,
    Domains =	case StateData#state.authenticated of
		    true -> 
			[StateData#state.auth_domain];
		    false ->
			Connections = StateData#state.connections,
			[D || {{D, _}, established} <- 
			    dict:to_list(Connections)]
		end,
    Infos = [{direction, in},
	     {statename, StateName},
	     {addr, Addr},
	     {port, Port},
	     {streamid, StateData#state.streamid},
	     {tls, StateData#state.tls},
	     {tls_enabled, StateData#state.tls_enabled},
	     {tls_options, StateData#state.tls_options},
	     {authenticated, StateData#state.authenticated},
	     {shaper, StateData#state.shaper},
	     {sockmod, SockMod},
	     {domains, Domains}
	    ],
    Reply = {state_infos, Infos},
    {reply,Reply,StateName,StateData};

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_info({send_text, Text}, StateName, StateData) ->
    send_text(StateData, Text),
    {next_state, StateName, StateData};

handle_info({timeout, Timer, _}, _StateName,
	    #state{timer = Timer} = StateData) ->
    {stop, normal, StateData};

handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.


%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(Reason, _StateName, StateData) ->
    ?DEBUG("terminated: ~p", [Reason]),
    case Reason of
	    {process_limit, _} ->
		    [ejabberd_s2s:external_host_overloaded(Host) || Host <- get_external_hosts(StateData)];
	    _ ->
		    ok
    end,
    (StateData#state.sockmod):close(StateData#state.socket),
    ok.

get_external_hosts(StateData) ->
    case StateData#state.authenticated of
	    true ->
		[StateData#state.auth_domain];
	    false ->
		Connections = StateData#state.connections,
		[D || {{D, _}, established} <- dict:to_list(Connections)]
    end.

%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State) ->
    State.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

send_text(StateData, Text) ->
    (StateData#state.sockmod):send(StateData#state.socket, Text).


send_element(StateData, #xmlel{ns = ?NS_XMPP, name = 'stream'} = El) ->
    send_text(StateData, exmpp_stream:to_iolist(El));
send_element(StateData, El) ->
    send_text(StateData, exmpp_stanza:to_iolist(El)).


change_shaper(StateData, Host, JID) ->
    Shaper = acl:match_rule(Host, StateData#state.shaper, JID),
    (StateData#state.sockmod):change_shaper(StateData#state.socket, Shaper).


new_id() ->
    randoms:get_string().

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive
	{timeout, Timer, _} ->
	    ok
    after 0 ->
	    ok
    end.


is_key_packet(#xmlel{ns = ?NS_DIALBACK, name = 'result',
  attrs = Attrs} = El) ->
    {key,
     binary_to_list(exmpp_stanza:get_recipient_from_attrs(Attrs)),
     binary_to_list(exmpp_stanza:get_sender_from_attrs(Attrs)),
     exmpp_stanza:get_id_from_attrs(Attrs),
     exmpp_xml:get_cdata_as_list(El)};
is_key_packet(#xmlel{ns = ?NS_DIALBACK, name = 'verify',
  attrs = Attrs} = El) ->
    {verify,
     binary_to_list(exmpp_stanza:get_recipient_from_attrs(Attrs)),
     binary_to_list(exmpp_stanza:get_sender_from_attrs(Attrs)),
     exmpp_stanza:get_id_from_attrs(Attrs),
     exmpp_xml:get_cdata_as_list(El)};
is_key_packet(_) ->
    false.


get_cert_domains(Cert) ->
    {rdnSequence, Subject} =
	(Cert#'Certificate'.tbsCertificate)#'TBSCertificate'.subject,
    Extensions =
	(Cert#'Certificate'.tbsCertificate)#'TBSCertificate'.extensions,
    lists:flatmap(
      fun(#'AttributeTypeAndValue'{type = ?'id-at-commonName',
				   value = Val}) ->
	      case ?PKIXEXPLICIT:decode('X520CommonName', Val) of
		  {ok, {_, D1}} ->
		      D = if
			      is_list(D1) -> D1;
			      is_binary(D1) -> binary_to_list(D1);
			      true -> error
			  end,
		      if
			  D /= error ->
                  JID  = exmpp_jid:parse(D),
			      case {exmpp_jid:prep_node_as_list(JID),
                        exmpp_jid:prep_domain_as_list(JID),
                        exmpp_jid:prep_resource_as_list(JID)} of
				      {undefined, LD, undefined} ->
				      [LD];
				  _ ->
				      []
			      end;
			  true ->
			      []
		      end;
		  _ ->
		      []
	      end;
	 (_) ->
	      []
      end, lists:flatten(Subject)) ++
	lists:flatmap(
	  fun(#'Extension'{extnID = ?'id-ce-subjectAltName',
			   extnValue = Val}) ->
		  BVal = if
			     is_list(Val) -> list_to_binary(Val);
			     is_binary(Val) -> Val;
			     true -> Val
			 end,
		  case ?PKIXIMPLICIT:decode('SubjectAltName', BVal) of
		      {ok, SANs} ->
			  lists:flatmap(
			    fun({otherName,
				 #'AnotherName'{'type-id' = ?'id-on-xmppAddr',
						value = XmppAddr
					       }}) ->
				    case 'XmppAddr':decode(
					   'XmppAddr', XmppAddr) of
					{ok, D} when is_binary(D) ->
                        JID2 = exmpp_jid:parse(binary_to_list(D)),  
					    case {exmpp_jid:prep_node_as_list(JID2),
                              exmpp_jid:prep_domain_as_list(JID2),
                              exmpp_jid:prep_resource_as_list(JID2)} of
						    { undefined, LD, undefined} ->
						    case idna:domain_utf8_to_ascii(LD) of
							false ->
							    [];
							PCLD ->
							    [PCLD]
						    end;
						_ ->
						    []
					    end;
					_ ->
					    []
				    end;
			       ({dNSName, D}) when is_list(D) ->
                    JID3 = exmpp_jid:parse(D),
				    case {exmpp_jid:prep_node_as_list(JID3),
                          exmpp_jid:prep_domain_as_list(JID3),
                          exmpp_jid:prep_resource_as_list(JID3)} of
					{undefined, LD, undefined} ->
					    [LD];
					_ ->
					    []
				    end;
			       (_) ->
				    []
			    end, SANs);
		      _ ->
			  []
		  end;
	     (_) ->
		  []
	  end, Extensions).

match_domain(Domain, Domain) ->
    true;
match_domain(Domain, Pattern) ->
    DLabels = string:tokens(Domain, "."),
    PLabels = string:tokens(Pattern, "."),
    match_labels(DLabels, PLabels).

match_labels([], []) ->
    true;
match_labels([], [_ | _]) ->
    false;
match_labels([_ | _], []) ->
    false;
match_labels([DL | DLabels], [PL | PLabels]) ->
    case lists:all(fun(C) -> (($a =< C) andalso (C =< $z))
				 orelse (($0 =< C) andalso (C =< $9))
				 orelse (C == $-) orelse (C == $*)
		   end, PL) of
	true ->
	    Regexp = xmerl_regexp:sh_to_awk(PL),
	    case re:run(DL, Regexp, [{capture, none}]) of
		match ->
		    match_labels(DLabels, PLabels);
		nomatch ->
		    false
	    end;
	false ->
	    false
    end.
