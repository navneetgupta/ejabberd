%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 16 Dec 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_s2s_out).
-behaviour(xmpp_stream_out).
-behaviour(ejabberd_config).

%% ejabberd_config callbacks
-export([opt_type/1, transform_options/1]).
%% xmpp_stream_out callbacks
-export([tls_options/1, tls_required/1, tls_verify/1, tls_enabled/1,
	 handle_auth_success/2, handle_auth_failure/3, handle_packet/2,
	 handle_stream_end/2, handle_stream_close/2,
	 handle_recv/3, handle_send/4, handle_cdata/2,
	 handle_stream_established/1, handle_timeout/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
%% Hooks
-export([process_auth_result/2, process_closed/2, handle_unexpected_info/2,
	 handle_unexpected_cast/2]).
%% API
-export([start/3, start_link/3, connect/1, close/1, stop/1, send/2,
	 route/2, establish/1, update_state/2, add_hooks/0]).

-include("ejabberd.hrl").
-include("xmpp.hrl").
-include("logger.hrl").

-type state() :: map().
-export_type([state/0]).

%%%===================================================================
%%% API
%%%===================================================================
start(From, To, Opts) ->
    xmpp_stream_out:start(?MODULE, [ejabberd_socket, From, To, Opts],
			  ejabberd_config:fsm_limit_opts([])).

start_link(From, To, Opts) ->
    xmpp_stream_out:start_link(?MODULE, [ejabberd_socket, From, To, Opts],
			       ejabberd_config:fsm_limit_opts([])).

connect(Ref) ->
    xmpp_stream_out:connect(Ref).

close(Ref) ->
    xmpp_stream_out:close(Ref).

stop(Ref) ->
    xmpp_stream_out:stop(Ref).

-spec send(pid(), xmpp_element()) -> ok;
	  (state(), xmpp_element()) -> state().
send(Stream, Pkt) ->
    xmpp_stream_out:send(Stream, Pkt).

-spec route(pid(), xmpp_element()) -> ok.
route(Ref, Pkt) ->
    Ref ! {route, Pkt}.

-spec establish(state()) -> state().
establish(State) ->
    xmpp_stream_out:establish(State).

-spec update_state(pid(), fun((state()) -> state()) |
		   {module(), atom(), list()}) -> ok.
update_state(Ref, Callback) ->
    xmpp_stream_out:cast(Ref, {update_state, Callback}).

-spec add_hooks() -> ok.
add_hooks() ->
    lists:foreach(
      fun(Host) ->
	      ejabberd_hooks:add(s2s_out_auth_result, Host, ?MODULE,
				 process_auth_result, 100),
	      ejabberd_hooks:add(s2s_out_closed, Host, ?MODULE,
				 process_closed, 100),
	      ejabberd_hooks:add(s2s_out_handle_info, Host, ?MODULE,
				 handle_unexpected_info, 100),
	      ejabberd_hooks:add(s2s_out_handle_cast, Host, ?MODULE,
				 handle_unexpected_cast, 100)
      end, ?MYHOSTS).

%%%===================================================================
%%% Hooks
%%%===================================================================
process_auth_result(#{server := LServer, remote_server := RServer} = State,
		    false) ->
    Delay = get_delay(),
    ?INFO_MSG("Closing outbound s2s connection ~s -> ~s: authentication failed;"
	      " bouncing for ~p seconds",
	      [LServer, RServer, Delay]),
    State1 = close(State),
    State2 = bounce_queue(State1),
    xmpp_stream_out:set_timeout(State2, timer:seconds(Delay));
process_auth_result(State, true) ->
    State.

process_closed(#{server := LServer, remote_server := RServer} = State,
	       _Reason) ->
    Delay = get_delay(),
    ?INFO_MSG("Closing outbound s2s connection ~s -> ~s: ~s; "
	      "bouncing for ~p seconds",
	      [LServer, RServer,
	       try maps:get(stop_reason, State) of
		   {error, Why} -> xmpp_stream_out:format_error(Why)
	       catch _:undef -> <<"unexplained reason">>
	       end,
	       Delay]),
    State1 = bounce_queue(State),
    xmpp_stream_out:set_timeout(State1, timer:seconds(Delay)).

handle_unexpected_info(State, Info) ->
    ?WARNING_MSG("got unexpected info: ~p", [Info]),
    State.

handle_unexpected_cast(State, Msg) ->
    ?WARNING_MSG("got unexpected cast: ~p", [Msg]),
    State.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
tls_options(#{server := LServer}) ->
    ejabberd_s2s:tls_options(LServer, []).

tls_required(#{server := LServer}) ->
    ejabberd_s2s:tls_required(LServer).

tls_verify(#{server := LServer}) ->
    ejabberd_s2s:tls_verify(LServer).

tls_enabled(#{server := LServer}) ->
    ejabberd_s2s:tls_enabled(LServer).

handle_auth_success(Mech, #{socket := Socket, ip := IP,
			    remote_server := RServer,
			    server := LServer} = State) ->
    ?INFO_MSG("(~s) Accepted outbound s2s ~s authentication ~s -> ~s (~s)",
	      [ejabberd_socket:pp(Socket), Mech, LServer, RServer,
	       ejabberd_config:may_hide_data(jlib:ip_to_list(IP))]),
    ejabberd_hooks:run_fold(s2s_out_auth_result, LServer, State, [true]).

handle_auth_failure(Mech, Reason,
		    #{socket := Socket, ip := IP,
		      remote_server := RServer,
		      server := LServer} = State) ->
    ?INFO_MSG("(~s) Failed outbound s2s ~s authentication ~s -> ~s (~s): ~s",
	      [ejabberd_socket:pp(Socket), Mech, LServer, RServer,
	       ejabberd_config:may_hide_data(jlib:ip_to_list(IP)), Reason]),
    State1 = State#{on_route => bounce,
		    stop_reason => {error, {auth, Reason}}},
    ejabberd_hooks:run_fold(s2s_out_auth_result, LServer, State1, [false]).

handle_packet(Pkt, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_packet, LServer, State, [Pkt]).

handle_stream_end(Reason, #{server := LServer} = State) ->
    State1 = State#{on_route => bounce, stop_reason => Reason},
    ejabberd_hooks:run_fold(s2s_out_closed, LServer, State1, [normal]).

handle_stream_close(Reason, #{server := LServer} = State) ->
    State1 = State#{on_route => bounce, stop_reason => Reason},
    ejabberd_hooks:run_fold(s2s_out_closed, LServer, State1, [Reason]).

handle_stream_established(State) ->
    State1 = State#{on_route => send},
    State2 = resend_queue(State1),
    set_idle_timeout(State2).

handle_cdata(Data, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_handle_cdata, LServer, State, [Data]).

handle_recv(El, Pkt, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_handle_recv, LServer, State, [El, Pkt]).

handle_send(Pkt, El, Data, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_handle_send, LServer,
			    State, [Pkt, El, Data]).

handle_timeout(#{server := LServer, remote_server := RServer,
		 on_route := Action} = State) ->
    case Action of
	bounce -> stop(State);
	queue -> send(State, xmpp:serr_connection_timeout());
	send ->
	    ?INFO_MSG("Closing outbound s2s connection ~s -> ~s: inactive",
		      [LServer, RServer]),
	    stop(State)
    end.

init([#{server := LServer, remote_server := RServer} = State, Opts]) ->
    State1 = State#{on_route => queue,
		    queue => queue:new(),
		    xmlns => ?NS_SERVER,
		    lang => ?MYLANG,
		    shaper => none},
    ?INFO_MSG("Outbound s2s connection started: ~s -> ~s",
	      [LServer, RServer]),
    ejabberd_hooks:run_fold(s2s_out_init, LServer, {ok, State1}, [Opts]).

handle_call(Request, From, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_handle_call, LServer, State, [Request, From]).

handle_cast({update_state, Fun}, State) ->
    case Fun of
	{M, F, A} -> erlang:apply(M, F, [State|A]);
	_ when is_function(Fun) -> Fun(State)
    end;
handle_cast(Msg, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_handle_cast, LServer, State, [Msg]).

handle_info({route, Pkt}, #{queue := Q, on_route := Action} = State) ->
    case Action of
	queue -> State#{queue => queue:in(Pkt, Q)};
	bounce -> bounce_packet(Pkt, State);
	send -> set_idle_timeout(send(State, Pkt))
    end;
handle_info(Info, #{server := LServer} = State) ->
    ejabberd_hooks:run_fold(s2s_out_handle_info, LServer, State, [Info]).

terminate(Reason, #{server := LServer,
		    remote_server := RServer} = State) ->
    ejabberd_s2s:remove_connection({LServer, RServer}, self()),
    State1 = case Reason of
		 normal -> State;
		 _ -> State#{stop_reason => {error, internal_failure}}
	     end,
    bounce_queue(State1),
    bounce_message_queue(State1).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec resend_queue(state()) -> state().
resend_queue(#{queue := Q} = State) ->
    State1 = State#{queue => queue:new()},
    jlib:queue_foldl(
      fun(Pkt, AccState) ->
	      send(AccState, Pkt)
      end, State1, Q).

-spec bounce_queue(state()) -> state().
bounce_queue(#{queue := Q} = State) ->
    State1 = State#{queue => queue:new()},
    jlib:queue_foldl(
      fun(Pkt, AccState) ->
	      bounce_packet(Pkt, AccState)
      end, State1, Q).

-spec bounce_message_queue(state()) -> state().
bounce_message_queue(State) ->
    receive
	{route, Pkt} ->
	    State1 = bounce_packet(Pkt, State),
	    bounce_message_queue(State1)
    after 0 ->
	    State
    end.

-spec bounce_packet(xmpp_element(), state()) -> state().
bounce_packet(Pkt, State) when ?is_stanza(Pkt) ->
    From = xmpp:get_from(Pkt),
    To = xmpp:get_to(Pkt),
    Lang = xmpp:get_lang(Pkt),
    Err = mk_bounce_error(Lang, State),
    ejabberd_router:route_error(To, From, Pkt, Err),
    State;
bounce_packet(_, State) ->
    State.

-spec mk_bounce_error(binary(), state()) -> stanza_error().
mk_bounce_error(Lang, State) ->
    try maps:get(stop_reason, State) of
	{error, internal_failure} ->
	    xmpp:err_internal_server_error();
	{error, Why} ->
	    Reason = xmpp_stream_out:format_error(Why),
	    case Why of
		{dns, _} ->
		    xmpp:err_remote_server_timeout(Reason, Lang);
		_ ->
		    xmpp:err_remote_server_not_found(Reason, Lang)
	    end
    catch _:{badkey, _} ->
	    xmpp:err_remote_server_not_found()
    end.

-spec get_delay() -> non_neg_integer().
get_delay() ->
    MaxDelay = ejabberd_config:get_option(
		 s2s_max_retry_delay,
		 fun(I) when is_integer(I), I > 0 -> I end,
		 300),
    crypto:rand_uniform(0, MaxDelay).

-spec set_idle_timeout(state()) -> state().
set_idle_timeout(#{on_route := send, server := LServer} = State) ->
    Timeout = ejabberd_s2s:get_idle_timeout(LServer),
    xmpp_stream_out:set_timeout(State, Timeout);
set_idle_timeout(State) ->
    State.

transform_options(Opts) ->
    lists:foldl(fun transform_options/2, [], Opts).

transform_options({outgoing_s2s_options, Families, Timeout}, Opts) ->
    ?WARNING_MSG("Option 'outgoing_s2s_options' is deprecated. "
                 "The option is still supported "
                 "but it is better to fix your config: "
                 "use 'outgoing_s2s_timeout' and "
                 "'outgoing_s2s_families' instead.", []),
    [{outgoing_s2s_families, Families},
     {outgoing_s2s_timeout, Timeout}
     | Opts];
transform_options({s2s_dns_options, S2SDNSOpts}, AllOpts) ->
    ?WARNING_MSG("Option 's2s_dns_options' is deprecated. "
                 "The option is still supported "
                 "but it is better to fix your config: "
                 "use 's2s_dns_timeout' and "
                 "'s2s_dns_retries' instead", []),
    lists:foldr(
      fun({timeout, T}, AccOpts) ->
              [{s2s_dns_timeout, T}|AccOpts];
         ({retries, R}, AccOpts) ->
              [{s2s_dns_retries, R}|AccOpts];
         (_, AccOpts) ->
              AccOpts
      end, AllOpts, S2SDNSOpts);
transform_options(Opt, Opts) ->
    [Opt|Opts].

opt_type(outgoing_s2s_families) ->
    fun (Families) ->
	    true = lists:all(fun (ipv4) -> true;
				 (ipv6) -> true
			     end,
			     Families),
	    Families
    end;
opt_type(outgoing_s2s_port) ->
    fun (I) when is_integer(I), I > 0, I =< 65536 -> I end;
opt_type(outgoing_s2s_timeout) ->
    fun (TimeOut) when is_integer(TimeOut), TimeOut > 0 ->
	    TimeOut;
	(infinity) -> infinity
    end;
opt_type(s2s_dns_retries) ->
    fun (I) when is_integer(I), I >= 0 -> I end;
opt_type(s2s_dns_timeout) ->
    fun (I) when is_integer(I), I >= 0 -> I end;
opt_type(s2s_max_retry_delay) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(_) ->
    [outgoing_s2s_families, outgoing_s2s_port, outgoing_s2s_timeout,
     s2s_dns_retries, s2s_dns_timeout, s2s_max_retry_delay].
