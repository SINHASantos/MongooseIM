%%%=============================================================================
%%% @copyright (C) 1999-2018, Erlang Solutions Ltd
%%% @author Denys Gonchar <denys.gonchar@erlang-solutions.com>
%%% @doc TLS backend based on standard Erlang's SSL application
%%% @end
%%%=============================================================================
-module(just_tls).
-copyright("2018, Erlang Solutions Ltd.").
-author('denys.gonchar@erlang-solutions.com').

-behaviour(mongoose_tls).

-include_lib("public_key/include/public_key.hrl").

-record(tls_socket, {verify_results = [],
                     ssl_socket
}).

-type tls_socket() :: #tls_socket{}.
-export_type([tls_socket/0]).

% mongoose_tls behaviour
-export([tcp_to_tls/2,
         send/2,
         recv_data/2,
         controlling_process/2,
         sockname/1,
         peername/1,
         setopts/2,
         get_peer_certificate/1,
         close/1]).

% API
-export([make_ssl_opts/1, make_cowboy_ssl_opts/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% APIs
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec tcp_to_tls(inet:socket(), mongoose_tls:options()) ->
          {ok, mongoose_tls:tls_socket()} | {error, any()}.
tcp_to_tls(TCPSocket, Options) ->
    inet:setopts(TCPSocket, [{active, false}]),
    {Ref1, Ret} = case Options of
                    #{connect := true} ->
                        % Currently unused as ejabberd_s2s_out uses fast_tls,
                        % and outgoing pools use Erlang SSL directly
                        % Do not set `fail_if_no_peer_cert_opt` for SSL client
                        % as it is a server only option.
                        {Ref, SSLOpts} = format_opts_with_ref(Options, client),
                        {Ref, ssl:connect(TCPSocket, SSLOpts)};
                    #{} ->
                        {Ref, SSLOpts} = format_opts_with_ref(Options, server),
                        {Ref, ssl:handshake(TCPSocket, SSLOpts, 5000)}
                 end,
    VerifyResults = receive_verify_results(Ref1),
    case Ret of
        {ok, SSLSocket} ->
            {ok, #tls_socket{ssl_socket = SSLSocket, verify_results = VerifyResults}};
        _ -> Ret
    end.

-spec send(tls_socket(), binary()) -> ok | {error, any()}.
send(#tls_socket{ssl_socket = SSLSocket}, Packet) -> ssl:send(SSLSocket, Packet).

-spec recv_data(tls_socket(), binary()) -> {ok, binary()} | {error, any()}.
recv_data(_, <<>>) ->
    %% such call is required for fast_tls to accomplish
    %% tls handshake, for just_tls we can ignore it
    {ok, <<>>};
recv_data(#tls_socket{ssl_socket = SSLSocket}, Data1) ->
    case ssl:recv(SSLSocket, 0, 0) of
        {ok, Data2} -> {ok, <<Data1/binary, Data2/binary>>};
        _ -> {ok, Data1}
    end.

-spec controlling_process(tls_socket(), pid()) -> ok | {error, any()}.
controlling_process(#tls_socket{ssl_socket = SSLSocket}, Pid) ->
    ssl:controlling_process(SSLSocket, Pid).

-spec sockname(tls_socket()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, any()}.
sockname(#tls_socket{ssl_socket = SSLSocket}) -> ssl:sockname(SSLSocket).

-spec peername(tls_socket()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, any()}.
peername(#tls_socket{ssl_socket = SSLSocket}) -> ssl:peername(SSLSocket).

-spec setopts(tls_socket(), Opts::list()) -> ok | {error, any()}.
setopts(#tls_socket{ssl_socket = SSLSocket}, Opts) -> ssl:setopts(SSLSocket, Opts).

-spec get_peer_certificate(tls_socket()) ->
    {ok, Cert::any()} | {bad_cert, bitstring()} | no_peer_cert.
get_peer_certificate(#tls_socket{verify_results = [], ssl_socket = SSLSocket}) ->
    case ssl:peercert(SSLSocket) of
        {ok, PeerCert} ->
            Cert = public_key:pkix_decode_cert(PeerCert, plain),
            {ok, Cert};
        _ -> no_peer_cert
    end;
get_peer_certificate(#tls_socket{verify_results = [Err | _]}) ->
    {bad_cert, error_to_list(Err)}.

-spec close(tls_socket()) -> ok.
close(#tls_socket{ssl_socket = SSLSocket}) ->
    ssl:close(SSLSocket).

%% @doc Prepare SSL options for direct use of ssl:connect/2 (client side)
%% The `disconnect_on_failure' option is expected to be unset or true
-spec make_ssl_opts(mongoose_tls:options()) -> [ssl:tls_option()].
make_ssl_opts(#{verify_mode := Mode} = Opts) ->
    SslOpts = format_opts(Opts, client),
    [{verify_fun, verify_fun(Mode)} | SslOpts].

%% @doc Prepare SSL options for direct use of ssl:handshake/2 (server side)
%% The `disconnect_on_failure' option is expected to be unset or true
-spec make_cowboy_ssl_opts(mongoose_tls:options()) -> [ssl:tls_option()].
make_cowboy_ssl_opts(#{verify_mode := Mode} = Opts) ->
    SslOpts = format_opts(Opts, server),
    [{verify_fun, verify_fun(Mode)} | SslOpts].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% local functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

format_opts_with_ref(Opts, ClientOrServer) ->
    SslOpts0 = format_opts(Opts, ClientOrServer),
    {Ref, VerifyFun} = verify_fun_opt(Opts),
    SslOpts = [{verify_fun, VerifyFun} | SslOpts0],
    {Ref, SslOpts}.

format_opts(Opts, ClientOrServer) ->
    SslOpts0 = maps:to_list(maps:with(ssl_option_keys(), Opts)),
    SslOpts1 = verify_opts(SslOpts0, Opts),
    SslOpts2 = hibernate_opts(SslOpts1, Opts),
    case ClientOrServer of
        client -> sni_opts(SslOpts2, Opts);
        server -> fail_if_no_peer_cert_opts(SslOpts2, Opts)
    end.

ssl_option_keys() ->
    [certfile, cacertfile, ciphers, keyfile, password, versions, dhfile].

%% accept empty peer certificate if explicitly requested not to fail
fail_if_no_peer_cert_opts(Opts, #{disconnect_on_failure := false}) ->
    [{fail_if_no_peer_cert, false} | Opts];
fail_if_no_peer_cert_opts(Opts, #{verify_mode := Mode})
  when Mode =:= peer; Mode =:= selfsigned_peer ->
    [{fail_if_no_peer_cert, true} | Opts];
fail_if_no_peer_cert_opts(Opts, #{}) ->
    [{fail_if_no_peer_cert, false} | Opts].

hibernate_opts(Opts, #{hibernate_after := Timeout}) ->
    [{hibernate_after, Timeout} | Opts];
hibernate_opts(Opts, #{}) ->
    Opts.

verify_opts(Opts, #{verify_mode := none}) ->
    [{verify, verify_none} | Opts];
verify_opts(Opts, #{}) ->
    [{verify, verify_peer} | Opts].

sni_opts(Opts, #{server_name_indication := #{enabled := false}}) ->
    [{server_name_indication, disable} | Opts];
sni_opts(Opts, #{server_name_indication := #{enabled := true, host := SNIHost, protocol := default}}) ->
    [{server_name_indication, SNIHost} | Opts];
sni_opts(Opts, #{server_name_indication := #{enabled := true, host := SNIHost, protocol := https}}) ->
    [{server_name_indication, SNIHost},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]} | Opts];
sni_opts(Opts, #{}) ->
    Opts.

%% This function translates TLS options to the function
%% which will later be used when TCP socket is upgraded to TLS
%%  `verify_mode` is one of the following:
%%     none - no validation of the clients certificate - any cert is accepted.
%%     peer - standard verification of the certificate.
%%     selfsigned_peer - the same as peer but also accepts self-signed certificates
%%  `disconnect_on_failure` is a boolean parameter:
%%     true - drop connection if certificate verification failed
%%     false - connect anyway, but later return {bad_cert,Error}
%%             on certificate verification (the same as fast_tls do).
verify_fun_opt(#{verify_mode := Mode, disconnect_on_failure := false}) ->
    Ref = erlang:make_ref(),
    {Ref, verify_fun(Ref, Mode)};
verify_fun_opt(#{verify_mode := Mode}) ->
    {dummy_ref, verify_fun(Mode)}.

verify_fun(Ref, Mode) when is_reference(Ref) ->
    {Fun, State} = verify_fun(Mode),
    {verify_fun_wrapper(Ref, Fun), State}.

verify_fun_wrapper(Ref, Fun) when is_reference(Ref), is_function(Fun, 3) ->
    Pid = self(),
    fun(Cert, Event, UserState) ->
        Ret = Fun(Cert, Event, UserState),
        case {Ret, Event} of
            {{valid, _}, _} -> Ret;
            {{unknown, NewState}, {extension, #'Extension'{critical = true}}} ->
                send_verification_failure(Pid, Ref, unknown_critical_extension),
                {valid, NewState};
            {{unknown, _}, {extension, _}} -> Ret;
            {_, _} -> %% {fail,Reason} = Ret
                send_verification_failure(Pid, Ref, Ret),
                {valid, UserState} %return the last valid user state
        end
    end.

verify_fun(peer) ->
    {fun
         (_, {bad_cert, _} = R, _) -> {fail, R};
         (_, {extension, _}, S) -> {unknown, S};
         (_, valid, S) -> {valid, S};
         (_, valid_peer, S) -> {valid, S}
     end, []};
verify_fun(selfsigned_peer) ->
    {fun
         (_, {bad_cert, selfsigned_peer}, S) -> {valid, S};
         (_, {bad_cert, _} = R, _) -> {fail, R};
         (_, {extension, _}, S) -> {unknown, S};
         (_, valid, S) -> {valid, S};
         (_, valid_peer, S) -> {valid, S}
     end, []};
verify_fun(none) ->
    {fun(_, _, S) -> {valid, S} end, []}.


send_verification_failure(Pid, Ref, Reason) ->
    Pid ! {cert_verification_failure, Ref, Reason}.

receive_verify_results(dummy_ref) ->
    [];
receive_verify_results(Ref) ->
    receive_verify_results(Ref, []).

receive_verify_results(Ref, Acc) ->
    receive
        {cert_verification_failure, Ref, Reason} ->
            receive_verify_results(Ref, [Reason | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

error_to_list(_Error) ->
    %TODO: implement later if needed
    "verify_fun failed".
