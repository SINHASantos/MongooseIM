%%%===================================================================
%%% @copyright (C) 2011, Erlang Solutions Ltd.
%%% @doc Suite for testing mod_sic module
%%% @end
%%%===================================================================

-module(sic_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("exml/include/exml.hrl").

-define(NS_SIC, <<"urn:xmpp:sic:1">>).

-import(distributed_helper, [mim/0,
                             require_rpc_nodes/1,
                             rpc/4]).

-import(domain_helper, [host_type/0]).

%%%===================================================================
%%% Suite configuration
%%%===================================================================

all() ->
    [{group, mod_sic_tests}].

all_tests() ->
    [user_sic, forbidden_user_sic].

groups() ->
    [{mod_sic_tests, [sequence], all_tests()}].

suite() ->
    require_rpc_nodes([mim]) ++ escalus:suite().

%%%===================================================================
%%% Init & teardown
%%%===================================================================

init_per_suite(Config0) ->
    Config1 = escalus:init_per_suite(Config0),
    escalus:create_users(Config1, escalus:get_users([alice, bob])).

end_per_suite(Config) ->
    escalus:delete_users(Config, escalus:get_users([alice, bob])),
    escalus:end_per_suite(Config).

init_per_group(mod_sic_tests, Config) ->
    Config1 = dynamic_modules:save_modules(host_type(), Config),
    dynamic_modules:ensure_modules(host_type(), [{mod_sic, config_parser_helper:default_mod_config(mod_sic)}]),
    Config1;
init_per_group(_GroupName, Config) ->
    Config.

end_per_group(mod_sic_tests, Config) ->
    dynamic_modules:restore_modules(Config);
end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

%%%===================================================================
%%% offline tests
%%%===================================================================

%% Retrieve my IP
user_sic(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->
        %% Alice sends a SIC IQ stanza
        escalus:send(Alice, sic_iq_get()),
        %% Alice expects IQ result with client IP address
        Stanza = escalus:wait_for_stanza(Alice),
        escalus:assert(is_sic_response(), Stanza)
    end).

%% Try to retrieve other user's IP
forbidden_user_sic(Config) ->
    escalus:story(Config, [{alice, 1}, {bob, 1}], fun(Alice, _Bob) ->
        %% Alice sends a SIC IQ stanza to get Bob's IP
        escalus:send(Alice, sic_iq_get(escalus_users:get_jid(Config, bob))),
        %% Alice should get <forbidden/> error
        Stanza = escalus:wait_for_stanza(Alice),
        escalus:assert(is_error, [<<"auth">>, <<"forbidden">>], Stanza)
    end).

%%%===================================================================
%%% Custom predicates
%%%===================================================================

is_sic_response() ->
    fun(Stanza) ->
        escalus_pred:is_iq(<<"result">>, Stanza)
        andalso
        ?NS_SIC == exml_query:path(Stanza, [{element, <<"address">>}, {attr, <<"xmlns">>}])
        andalso
        <<"127.0.0.1">> == exml_query:path(Stanza, [{element, <<"address">>}, {element, <<"ip">>}, cdata])
        andalso
        is_binary(exml_query:path(Stanza, [{element, <<"address">>}, {element, <<"port">>}, cdata]))
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

sic_iq_get() ->
    escalus_stanza:iq(<<"get">>, [#xmlel{
        name = <<"address">>,
        attrs = #{<<"xmlns">> => ?NS_SIC},
        children = []
    }]).

sic_iq_get(To) ->
    escalus_stanza:to(sic_iq_get(), To).
