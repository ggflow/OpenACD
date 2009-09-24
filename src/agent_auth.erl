%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Connection to the local authenication cache and integration to another module.
%% Authentication is first checked by the integration module (if any).  If that fails, 
%% this module will fall back to it's local cache in the mnesia 'agent_auth' table.
%% the cache table is both ram and disc copies on all nodes.

-module(agent_auth).

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-ifdef(EUNIT).
	-include_lib("eunit/include/eunit.hrl").
-endif.


%% API
-export([
	auth/2,
	build_tables/0
]).
-export([
	cache/4,
	destroy/1,
	merge/3,
	add_agent/5,
	add_agent/1,
	set_agent/5,
	set_agent/6,
	set_agent/2,
	get_agent/1,
	get_agents/0,
	get_agents/1
]).
-export([
	new_profile/2,
	set_profile/3,
	get_profile/1,
	get_profiles/0,
	destroy_profile/1
	]).
%% API for release options
-export([
	new_release/1,
	destroy_release/1,
	update_release/2,
	get_releases/0
	]).

%%====================================================================
%% API
%%====================================================================

%% @doc Add `#release_opt{} Rec' to the database. 
-spec(new_release/1 :: (Rec :: #release_opt{}) -> {'atomic', 'ok'}).
new_release(Rec) when is_record(Rec, release_opt) ->
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

%% @doc Remove the release option `string() Label' from the database.
-spec(destroy_release/1 :: (Label :: string()) -> {'atomic', 'ok'}).
destroy_release(Label) when is_list(Label) ->
	F = fun() ->
		mnesia:delete({release_opt, Label})
	end,
	mnesia:transaction(F).

%% @doc Update the release option `string() Label' to `#release_opt{} Rec'.
-spec(update_release/2 :: (Label :: string(), Rec :: #release_opt{}) -> {'atomic', 'ok'}).
update_release(Label, Rec) when is_list(Label), is_record(Rec, release_opt) ->
	F = fun() ->
		mnesia:delete({release_opt, Label}),
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

%% @doc Get all `#release_opt'.
-spec(get_releases/0 :: () -> [#release_opt{}]).
get_releases() ->
	F = fun() ->
		Select = qlc:q([X || X <- mnesia:table(release_opt)]),
		qlc:e(Select)
	end,
	{atomic, Opts} = mnesia:transaction(F),
	lists:sort(Opts).

%% @doc Create a new agent profile `string() Name' with `[atom()] Skills'.
-spec(new_profile/2 :: (Name :: string(), Skills :: [atom()]) -> {'atomic', 'ok'}).
new_profile(Name, Skills) ->
	Rec = #agent_profile{name = Name, skills = Skills},
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

%% @doc Update the proflie `string() Oldname' to `string() Newname' with `[atom()] Skills'.
-spec(set_profile/3 :: (Oldname :: string(), Newname :: string(), Skills :: [atom()]) -> {'atomic', 'ok'}).
set_profile(Oldname, Oldname, Skills) ->
	Rec = #agent_profile{name = Oldname, skills = Skills},
	F = fun() ->
		mnesia:delete({agent_profile, Oldname}),
		mnesia:write(Rec)
	end,
	mnesia:transaction(F);
set_profile(Oldname, Newname, Skills) ->
	Rec = #agent_profile{name = Newname, skills = Skills},
	F = fun() ->
		mnesia:delete({agent_profile, Oldname}),
		mnesia:write(Rec),
		Agents = get_agents(Oldname),
		Update = fun(Arec) ->
			Newagent = Arec#agent_auth{profile = Newname},
			destroy(Arec#agent_auth.login),
			mnesia:write(Newagent)
		end,
		lists:map(Update, Agents),
		ok
	end,
	mnesia:transaction(F).

%% @doc Remove the profile `string() Name'.  Returns `error' if you try to remove the profile `"Default"'.
-spec(destroy_profile/1 :: (Name :: string()) -> 'error' | {'atomic', 'ok'}).
destroy_profile("Default") ->
	error;
destroy_profile(Name) ->
	F = fun() ->
		mnesia:delete({agent_profile, Name}),
		Agents = get_agents(Name),
		Update = fun(Arec) ->
			Newagent = Arec#agent_auth{profile = "Default"},
			destroy(Arec#agent_auth.login),
			mnesia:write(Newagent)
		end,
		lists:map(Update, Agents),
		ok
	end,
	mnesia:transaction(F).

%% @doc Gets the proflie `string() Name'
-spec(get_profile/1 :: (Name :: string()) -> {string(), [atom()]} | 'undefined').
get_profile(Name) ->
	F = fun() ->
		mnesia:read({agent_profile, Name})
	end,
	case mnesia:transaction(F) of
		{atomic, []} ->
			undefined;
		{atomic, [Profile]} ->
			{Profile#agent_profile.name, Profile#agent_profile.skills}
	end.

%% @doc Return all profiles as `[{string() Name, [atom] Skills}]'.
-spec(get_profiles/0 :: () -> [{string(), [atom()]}]).
get_profiles() ->
	F = fun() ->
		QH = qlc:q([ X || X <- mnesia:table(agent_profile)]),
		qlc:e(QH)
	end,
	{atomic, Profiles} = mnesia:transaction(F),
	Convert = fun(Profile) ->
		{Profile#agent_profile.name, Profile#agent_profile.skills}
	end,
	Cprofs = lists:map(Convert, Profiles),
	Sort = fun({Name1, _Skills1}, {Name2, _Skills2}) ->
		Name1 < Name2
	end,
	lists:sort(Sort, Cprofs).

%% @doc Update the agent `string() Oldlogin' without changing the password.
-spec(set_agent/5 :: (Oldlogin :: string(), Newlogin :: string(), Newskills :: [atom()], NewSecurity :: security_level(), Newprofile :: string()) -> {'atomic', 'ok'}).
set_agent(Oldlogin, Newlogin, Newskills, NewSecurity, Newprofile) ->
	Props = [
		{login, Newlogin},
		{skills, Newskills},
		{securitylevel, NewSecurity},
		{profile, Newprofile}
	],
	set_agent(Oldlogin, Props).

%% @doc Sets the agent `string() Oldlogin' with new data in `proplist Props'; 
%% does not change data that is not in the proplist.
-spec(set_agent/2 :: (Oldlogin :: string(), Props :: [{atom(), any()}]) -> {'atomic', 'ok'}).
set_agent(Oldlogin, Props) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Oldlogin]),
		[Agent] = qlc:e(QH),
		Newrec = build_agent_record(Props, Agent),
		destroy(Oldlogin),
		mnesia:write(Newrec#agent_auth{timestamp = util:now()}),
		ok
	end,
	mnesia:transaction(F).
	
%% @doc Update the agent `string() Oldlogin' with a new password (as well as everything else).
-spec(set_agent/6 :: (Oldlogin :: string(), Newlogin :: string(), Newpass :: string(), Newskills :: [atom()], NewSecurity :: security_level(), Newprofile :: string()) -> {'atomic', 'error'} | {'atomic', 'ok'}).
set_agent(Oldlogin, Newlogin, Newpass, Newskills, NewSecurity, Newprofile) ->
	Props = [
		{login, Newlogin},
		{password, Newpass},
		{skills, Newskills},
		{securitylevel, NewSecurity},
		{profile, Newprofile}
	],
	set_agent(Oldlogin, Props).

%% @doc Gets `#agent_auth{}' associated with `string() Login'.
-spec(get_agent/1 :: (Login :: string()) -> {'atomic', [#agent_auth{}]}).
get_agent(Login) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Login]),
		qlc:e(QH)
	end,
	mnesia:transaction(F).

%% @doc Gets All the agents.
-spec(get_agents/0 :: () -> [#agent_auth{}]).
get_agents() ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth)]),
		qlc:e(QH)
	end,
	{atomic, Agents} = mnesia:transaction(F),
	Sort = fun(#agent_auth{profile = P1}, #agent_auth{profile = P2}) ->
		P1 < P2
	end,
	lists:sort(Sort, Agents).

%% @doc Gets all the agents associated with `string() Profile'.
-spec(get_agents/1 :: (Profile :: string()) -> [#agent_auth{}]).
get_agents(Profile) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.profile =:= Profile]),
		qlc:e(QH)
	end,
	{atomic, Agents} = mnesia:transaction(F),
	Sort = fun(#agent_auth{login = L1}, #agent_auth{login = L2}) ->
		 L1 < L2
	end,
	lists:sort(Sort, Agents).

%% @doc Utility function to handle merging data after a net split.  Takes the 
%% given nodes, selects all records with a timestamp greater than the given 
%% time, merges them, and passes the resulting list back to Pid.  Best if used
%% inside a spawn.
-spec(merge/3 :: (Nodes :: [atom()], Time :: pos_integer(), Replyto :: pid()) -> 'ok' | {'error', any()}).
merge(Nodes, Time, Replyto) ->
	Auths = merge_agent_auth(Nodes, Time),
	Profs = merge_profiles(Nodes, Time),
	Rels = merge_release(Nodes, Time),
	Recs = lists:append([Auths, Profs, Rels]),
	Replyto ! {merge_complete, agent_auth, Recs},
	ok.

merge_agent_auth(Nodes, Time) ->
	?DEBUG("Staring merge.  Nodes:  ~p.  Time:  ~B", [Nodes, Time]),
	F = fun() ->
		QH = qlc:q([Auth || Auth <- mnesia:table(agent_auth), Auth#agent_auth.timestamp >= Time]),
		qlc:e(QH)
	end,
	merge_results(query_nodes(Nodes, F)).

merge_results(Res) ->
	?DEBUG("Merging:  ~p", [Res]),
	merge_results_loop([], Res).

merge_results_loop(Return, []) ->
	?DEBUG("Merge complete:  ~p", [Return]),
	Return;
merge_results_loop(Return, [{atomic, List} | Tail]) ->
	Newreturn = diff_recs(Return, List),
	merge_results_loop(Newreturn, Tail).

merge_profiles(Nodes, Time) ->
	F = fun() ->
		QH = qlc:q([Prof || Prof <- mnesia:table(agent_profile), Prof#agent_profile.timestamp >= Time]),
		qlc:e(QH)
	end,
	merge_results(query_nodes(Nodes, F)).

merge_release(Nodes, Time) ->
	F = fun() ->
		QH = qlc:q([Rel || Rel <- mnesia:table(release_opt), Rel#release_opt.timestamp >= Time]),
		qlc:e(QH)
	end,
	merge_results(query_nodes(Nodes, F)).

query_nodes(Nodes, Fun) ->
	query_nodes(Nodes, Fun, []).

query_nodes([], _Fun, Acc) ->
	?DEBUG("Full acc:  ~p", [Acc]),
	Acc;
query_nodes([Node | Tail], Fun, Acc) ->
	Newacc = case rpc:call(Node, mnesia, transaction, [Fun]) of
		{atomic, Rows} = Rez ->
			?DEBUG("Node ~w Got the following rows:  ~p", [Node, Rows]),
			[Rez | Acc];
		_Else ->
			?WARNING("Unable to get rows during merge for node ~w", [Node]),
			Acc
	end,
	query_nodes(Tail, Fun, Newacc).

%% @doc Take the plaintext username and password and attempt to authenticate 
%% the agent.
-type(skill() :: atom() | {atom(), any()}).
-type(skill_list() :: [skill()]).
-type(profile_name() :: string()).
-spec(auth/2 :: (Username :: string(), Password :: string()) -> 'deny' | {'allow', skill_list(), security_level(), profile_name()}).
auth(Username, Password) ->
	try integration:agent_auth(Username, Password) of
		deny ->
			?INFO("integration denial for ~p", [Username]),
			destroy(Username),
			deny;
		{ok, Profile, Security} ->
			?INFO("integration allow for ~p", [Username]),
			cache(Username, Password, Profile, Security),
			local_auth(Username, Password);
		{error, nointegration} ->
			?INFO("No integration, local authing ~p", [Username]),
			local_auth(Username, Password)
	catch
		throw:{badreturn, Err} ->
			?WARNING("Integration gave a bad return of ~p", [Err]),
			local_auth(Username, Password)
	end.

%% @doc Starts mnesia and creates the tables.  If the tables already exist, returns `ok'.  Otherwise, a default username
%% of `"agent"' is stored with password `"Password123"' and skill `[english]'.
-spec(build_tables/0 :: () -> 'ok').
build_tables() ->
	?DEBUG("building tables...", []),
%	Nodes = lists:append([[node()], nodes()]),
	A = util:build_table(agent_auth, [
				{attributes, record_info(fields, agent_auth)},
				{disc_copies, [node()]}
			]),
	case A of
		{atomic, ok} ->
			F = fun() ->
				mnesia:write(#agent_auth{login="agent", password=util:bin_to_hexstr(erlang:md5("Password123")), skills=[english], profile="Default"}),
				mnesia:write(#agent_auth{login="administrator", password=util:bin_to_hexstr(erlang:md5("Password123")), securitylevel=admin, skills=[english], profile="Default"})
			end,
			case mnesia:transaction(F) of
				{atomic, ok} -> 
					ok;
				Else -> 
					Else
			end;
		_Else when A =:= copied; A =:= exists ->
			ok;
		_Else -> 
			A
	end,
	B = util:build_table(release_opt, [
		{attributes, record_info(fields, release_opt)},
		{disc_copies, [node()]}
	]),
	case B of
		{atomic, ok} ->
			ok;
		_Else2 when B =:= copied; B =:= exists ->
			ok;
		_Else2 ->
			B
	end,
	C = util:build_table(agent_profile, [
		{attributes, record_info(fields, agent_profile)},
		{disc_copies, [node()]}
	]),
	case C of
		{atomic, ok} -> 
			G = fun() ->
				mnesia:write(?DEFAULT_PROFILE)
			end,
			case mnesia:transaction(G) of
				{atomic, ok} -> 
					ok;
				Else2 -> 
					Else2
			end;
		_Else3 when C =:= copied; C =:= exists ->
			ok;
		_Else3 ->
			C
	end.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc Caches the passed `Username', `Password', `Skills', and `Security' type.  to the mnesia database.  
%% `Username' is the plaintext name and used as the key. 
%% `Password' is assumed to be plaintext; will be erlang:md5'ed.  `Security' is 
%% either `agent', `supervisor', or `admin'.
-type(profile() :: string()).
-type(profile_data() :: {profile(), skill_list()} | profile() | skill_list()).
-spec(cache/4 ::	(Username :: string(), Password :: string(), Profile :: profile_data(), Security :: 'agent' | 'supervisor' | 'admin') -> 
						{'atomic', 'ok'} | {'aborted', any()}).
cache(Username, Password, {Profile, Skills}, Security) ->
	F = fun() ->
		QH = qlc:q([A || A <- mnesia:table(agent_auth), A#agent_auth.login =:= Username]),
		Writerec = case qlc:e(QH) of
			[] ->
				#agent_auth{
					login = Username,
					password = util:bin_to_hexstr(erlang:md5(Password)),
					skills = [],
					securitylevel = Security,
					integrated = util:now(),
					profile = Profile
				};
			[Baserec] ->
				Baserec#agent_auth{
					password = util:bin_to_hexstr(erlang:md5(Password)),
					securitylevel = Security,
					integrated = util:now(),
					profile = Profile,
					skills = util:merge_skill_lists(Baserec#agent_auth.skills, Skills)
				}
		end,
		mnesia:write(Writerec)
	end,
	Out = mnesia:transaction(F),
	?DEBUG("Cache username result:  ~p", [Out]),
	Out;
cache(Username, Password, [Isskill | _Tail] = Skills, Security) when is_atom(Isskill); is_tuple(Isskill) ->
	case get_agent(Username) of
		{atomic, [Agent]} ->
			cache(Username, Password, {Agent#agent_auth.profile, Skills}, Security);
		{atomic, []} ->
			cache(Username, Password, {"Default", Skills}, Security)
	end;
cache(Username, Password, Profile, Security) ->
	cache(Username, Password, {Profile, []}, Security).
	
%% @doc adds a user to the local cache bypassing the integrated at check.  Note that unlike {@link cache/4} this expects the password 
%% in plain text!
-spec(add_agent/5 :: 
	(Username :: string(), Password :: string(), Skills :: [atom()], Security :: 'admin' | 'agent' | 'supervisor', Profile :: string()) -> 
		{'atomic', 'ok'}).
add_agent(Username, Password, Skills, Security, Profile) ->
	Rec = #agent_auth{
		login = Username,
		password = util:bin_to_hexstr(erlang:md5(Password)),
		skills = Skills,
		securitylevel = Security,
		profile = Profile},
	add_agent(Rec).

%% @doc adds a user to the local cache; more flexible than `add_agent/5'.
-spec(add_agent/1 :: (Proplist :: [{atom(), any()}, ...] | #agent_auth{}) -> {'atomic', 'ok'}).
add_agent(Proplist) when is_list(Proplist) ->
	Rec = build_agent_record(Proplist, #agent_auth{}),
	add_agent(Rec);
add_agent(Rec) when is_record(Rec, agent_auth) ->
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F).

%% @doc Removes the passed user with login of `Username' from the local cache.  Called when integration returns a deny.
-spec(destroy/1 :: (Username :: string()) -> {'atomic', 'ok'} | {'aborted', any()}).
destroy(Username) -> 
	F = fun() -> 
		mnesia:delete({agent_auth, Username})
	end,
	mnesia:transaction(F).

%% @private 
% Checks the `Username' and prehashed `Password' using the given `Salt' for the cached password.
% internally called by the auth callback; there should be no need to call this directly (aside from tests).
-spec(local_auth/2 :: (Username :: string(), Password :: string()) -> {'allow', [atom()], security_level(), string()} | 'deny').
local_auth(Username, BasePassword) -> 
	Password = util:bin_to_hexstr(erlang:md5(BasePassword)),
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Username, X#agent_auth.password =:= Password]),
		qlc:e(QH)
	end,
	case mnesia:transaction(F) of
		{atomic, [Agent]} when is_record(Agent, agent_auth) ->
			?DEBUG("Auth is coolbeans for ~p", [Username]),
			Skills = lists:umerge(lists:sort(Agent#agent_auth.skills), lists:sort(['_agent', '_node'])),
			{allow, Skills, Agent#agent_auth.securitylevel, Agent#agent_auth.profile};
		Else ->
			?DEBUG("Denying auth due to ~p", [Else]),
			deny
	end.

%% @doc Builds up an `#agent_auth{}' from the given `proplist() Proplist';
-spec(build_agent_record/2 :: (Proplist :: [{atom(), any()}], Rec :: #agent_auth{}) -> #agent_auth{}).
build_agent_record([], Rec) ->
	Rec;
build_agent_record([{login, Login} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{login = Login});
build_agent_record([{password, Password} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{password = Password});
build_agent_record([{skills, Skills} | Tail], Rec) when is_list(Skills) ->
	build_agent_record(Tail, Rec#agent_auth{skills = Skills});
build_agent_record([{securitylevel, Sec} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{securitylevel = Sec});
build_agent_record([{profile, Profile} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{profile = Profile});
build_agent_record([{firstname, Name} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{firstname = Name});
build_agent_record([{lastname, Name} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{lastname = Name}).

diff_recs(Left, Right) ->
	Sort = fun(A, B) when is_record(A, agent_auth) ->
			A#agent_auth.login < B#agent_auth.login;
		(A, B) when is_record(A, release_opt) ->
			A#release_opt.label < B#release_opt.label;
		(A, B) when is_record(A, agent_profile) ->
			A#agent_profile.name < B#agent_profile.name
	end,
	Sleft = lists:sort(Sort, Left),
	Sright = lists:sort(Sort, Right),
	diff_recs_loop(Sleft, Sright, []).

diff_recs_loop([], [], Acc) ->
	lists:reverse(Acc);
diff_recs_loop([_H | _T] = Left, [], Acc) ->
	lists:append(lists:reverse(Acc), Left);
diff_recs_loop([], [_H | _T] = Right, Acc) ->
	lists:append(lists:reverse(Acc), Right);
diff_recs_loop([Lhead | LTail] = Left, [Rhead | Rtail] = Right, Acc) ->
	case nom_equal(Lhead, Rhead) of
		true ->
			case timestamp_comp(Lhead, Rhead) of
				false ->
					diff_recs_loop(LTail, Rtail, [Lhead | Acc]);
				true ->
					diff_recs_loop(LTail, Rtail, [Rhead | Acc])
			end;
		false ->
			case nom_comp(Lhead, Rhead) of
				true ->
					diff_recs_loop(LTail, Right, [Lhead | Acc]);
				false ->
					diff_recs_loop(Left, Rtail, [Rhead | Acc])
			end
	end.
	
nom_equal(A, B) when is_record(A, agent_auth) ->
	A#agent_auth.login =:= B#agent_auth.login;
nom_equal(A, B) when is_record(A, release_opt) ->
	B#release_opt.label =:= A#release_opt.label;
nom_equal(A, B) when is_record(A, agent_profile) ->
	A#agent_profile.name =:= B#agent_profile.name.
	
nom_comp(A, B) when is_record(A, agent_auth) ->
	A#agent_auth.login < B#agent_auth.login;
nom_comp(A, B) when is_record(A, release_opt) ->
	A#release_opt.label < B#release_opt.label;
nom_comp(A, B) when is_record(A, agent_profile) ->
	A#agent_profile.name < B#agent_profile.name.

timestamp_comp(A, B) when is_record(A, agent_auth) ->
	A#agent_auth.timestamp < B#agent_auth.timestamp;
timestamp_comp(A, B) when is_record(B, release_opt) ->
	A#release_opt.timestamp < B#release_opt.timestamp;
timestamp_comp(A, B) when is_record(A, agent_profile) ->
	A#agent_profile.timestamp < B#agent_profile.timestamp.


-ifdef(EUNIT).

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------

auth_no_integration_test_() ->
	{setup,
	fun() -> 
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables()
	end,
	fun(_) -> 
		mnesia:stop(),
		mnesia:delete_schema([node()])
	end,
	[{"authing the default agent success",
	fun() ->
		?assertMatch({allow, _Skills, agent, "Default"}, auth("agent", "Password123"))
	end},
	{"auth an agent that doesn't exist",
	fun() ->
		?assertEqual(deny, auth("arnie", "goober"))
	end},
	{"don't auth with wrong pass",
	fun() ->
		?assertEqual(deny, auth("agent", "badpass"))
	end}]}.

auth_integration_test_() ->
	{foreach,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables(),
		{ok, Mock} = gen_server_mock:named({local, integration}),
		Mock
	end,
	fun(Mock) -> 
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		unregister(integration),
		gen_server_mock:stop(Mock)
	end,
	[fun(Mock) ->
		{"auth an agent that's not cached",
		fun() ->
			gen_server_mock:expect_call(Mock, fun({agent_auth, "testagent", "password"}, _, State) ->
				{ok, {ok, "Default", agent}, State}
			end),
			?assertMatch({allow, _Skills, agent, "Default"}, auth("testagent", "password")),
			?assertMatch({allow, _Skills, agent, "Default"}, local_auth("testagent", "password"))
		end}
	end,
	fun(Mock) ->
		{"auth an agent overwrites the cache",
		fun() ->
			cache("testagent", "password", "Default", agent),
			?assertMatch({allow, _Skills, agent, "Default"}, local_auth("testagent", "password")),
			gen_server_mock:expect_call(Mock, fun({agent_auth, "testagent", "newpass"}, _, State) ->
				{ok, {ok, "Default", agent}, State}
			end),
			?assertMatch({allow, _Skills, agent, "Default"}, auth("testagent", "newpass")),
			?assertMatch({allow, _Skills, agent, "Default"}, local_auth("testagent", "newpass")),
			?assertEqual(deny, local_auth("testagent", "password"))
		end}
	end,
	fun(Mock) ->
		{"integration denies, thus removing from cache",
		fun() ->
			?assertMatch({allow, _, agent, "Default"}, local_auth("agent", "Password123")),
			gen_server_mock:expect_call(Mock, fun({agent_auth, "agent", "Password123"}, _, State) ->
				{ok, deny, State}
			end),
			?assertEqual(deny, auth("agent", "Password123")),
			?assertEqual(deny, local_auth("agent", "Password123"))
		end}
	end,
	fun(Mock) ->
		{"integration fails",
		fun() ->
			gen_server_mock:expect_call(Mock, fun({agent_auth, "agent", "Password123"}, _, State) ->
				{ok, gooberpants, State}
			end),
			?assertMatch({allow, _Skills, agent, "Default"}, auth("agent", "Password123")),
			?assertMatch({allow, _Skills, agent, "Default"}, local_auth("agent", "Password123"))
		end}
	end]}.

release_opt_test_() ->
	{
		foreach,
		fun() ->
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			build_tables()
		end,
		fun(_) -> 
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			{
				"Add new release option",
				fun() ->
					Releaseopt = #release_opt{label = "testopt", id = 500, bias = 1},
					new_release(Releaseopt),
					F = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "testopt"]),
						qlc:e(Select)
					end,
					?assertMatch({atomic, [#release_opt{label ="testopt"}]}, mnesia:transaction(F))
				end
			},
			{
				"Destroy a release option",
				fun() ->
					Releaseopt = #release_opt{label = "testopt", id = 500, bias = 1},
					new_release(Releaseopt),
					destroy_release("testopt"),
					F = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "testopt"]),
						qlc:e(Select)
					end,
					?assertEqual({atomic, []}, mnesia:transaction(F))
				end
			},
			{
				"Update a release option",
				fun() ->
					Oldopt = #release_opt{label = "oldopt", id = 500, bias = 1},
					Newopt = #release_opt{label = "newopt", id = 500, bias = 1},
					new_release(Oldopt),
					update_release("oldopt", Newopt),
					Getold = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "oldopt"]),
						qlc:e(Select)
					end,
					Getnew = fun() ->
						Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "newopt"]),
						qlc:e(Select)
					end,
					?assertEqual({atomic, []}, mnesia:transaction(Getold)),
					?assertMatch({atomic, [#release_opt{label = "newopt"}]}, mnesia:transaction(Getnew))
				end
			},
			{
				"Get all release options",
				fun() ->
					Aopt = #release_opt{label = "aoption", id = 300, bias = 1},
					Bopt = #release_opt{label = "boption", id = 200, bias = 1},
					Copt = #release_opt{label = "coption", id = 100, bias = -1},
					new_release(Copt),
					new_release(Bopt),
					new_release(Aopt),
					?assertMatch([#release_opt{label = "aoption"}, #release_opt{label = "boption"}, #release_opt{label = "coption"}], get_releases())
				end
			}
		]
	}.

profile_test_() ->
	{
		foreach,
		fun() ->
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			build_tables()
		end,
		fun(_) -> 
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			{
				"Add a profile",
				fun() ->
					F = fun() ->
						QH = qlc:q([X || X <- mnesia:table(agent_profile), X#agent_profile.name =:= "test profile"]),
						qlc:e(QH)
					end,
					?assertEqual({atomic, []}, mnesia:transaction(F)),
					?assertEqual({atomic, ok}, new_profile("test profile", [testskill])),
					Test = #agent_profile{name = "test profile", skills = [testskill]},
					?assertEqual({atomic, [Test#agent_profile{name = "test profile"}]}, mnesia:transaction(F))
				end
			},
			{
				"Update a profile",
				fun() ->
					new_profile("inital", [english]),
					set_profile("initial", "new", [german]),
					?assertEqual(undefined, get_profile("initial")),
					?assertEqual({"new", [german]}, get_profile("new"))
				end
			},
			{
				"Remove a profile",
				fun() ->
					F = fun() ->
						QH = qlc:q([X || X <- mnesia:table(agent_profile), X#agent_profile.name =:= "test profile"]),
						qlc:e(QH)
					end,
					new_profile("test profile", [english]),
					?assertEqual({atomic, [#agent_profile{name = "test profile", skills=[english], timestamp = util:now()}]}, mnesia:transaction(F)),
					?assertEqual({atomic, ok}, destroy_profile("test profile")),
					?assertEqual({atomic, []}, mnesia:transaction(F))
				end
			},
			{
				"Get a profile",
				fun() ->
					?assertEqual(undefined, get_profile("noexists")),
					new_profile("test profile", [testskill]),
					?assertEqual({"test profile", [testskill]}, get_profile("test profile"))
				end
			},
			{
				"Get all profiles",
				fun() ->
					new_profile("B", [german]),
					new_profile("A", [english]),
					new_profile("C", [testskill]),
					F = fun() ->
						mnesia:delete({agent_profile, "Default"})
					end,
					mnesia:transaction(F),
					?CONSOLE("profs:  ~p", [get_profiles()]),
					?assertEqual([{"A", [english]}, {"B", [german]}, {"C", [testskill]}], get_profiles())
				end
			}
		]
	}.
	
diff_recs_test_() ->
	[{"agent_auth records",
	fun() ->
		Left = [
			#agent_auth{login = "A", timestamp = 1},
			#agent_auth{login = "B", timestamp = 3},
			#agent_auth{login = "C", timestamp = 5}
		],
		Right = [
			#agent_auth{login = "A", timestamp = 5},
			#agent_auth{login = "B", timestamp = 3},
			#agent_auth{login = "C", timestamp = 1}
		],
		Expected = [
			#agent_auth{login = "A", timestamp = 5},
			#agent_auth{login = "B", timestamp = 3},
			#agent_auth{login = "C", timestamp = 5}
		],
		?assertEqual(Expected, diff_recs(Left, Right))
	end},
	{"release_opts records",
	fun() ->
		Left = [
			#release_opt{label = "A", timestamp = 1},
			#release_opt{label = "B", timestamp = 3},
			#release_opt{label = "C", timestamp = 5}
		],
		Right = [
			#release_opt{label = "A", timestamp = 5},
			#release_opt{label = "B", timestamp = 3},
			#release_opt{label = "C", timestamp = 1}
		],
		Expected = [
			#release_opt{label = "A", timestamp = 5},
			#release_opt{label = "B", timestamp = 3},
			#release_opt{label = "C", timestamp = 5}
		],
		?assertEqual(Expected, diff_recs(Left, Right))
	end},
	{"agent_prof records",
	fun() ->
		Left = [
			#agent_profile{name = "A", timestamp = 1},
			#agent_profile{name = "B", timestamp = 3},
			#agent_profile{name = "C", timestamp = 5}
		],
		Right = [
			#agent_profile{name = "A", timestamp = 5},
			#agent_profile{name = "B", timestamp = 3},
			#agent_profile{name = "C", timestamp = 1}
		],
		Expected = [
			#agent_profile{name = "A", timestamp = 5},
			#agent_profile{name = "B", timestamp = 3},
			#agent_profile{name = "C", timestamp = 5}
		],
		?assertEqual(Expected, diff_recs(Left, Right))
	end},
	{"3 way merge",
	fun() ->
		One = [
			#agent_auth{login = "A", timestamp = 1},
			#agent_auth{login = "B", timestamp = 3}
		],
		Two = [
			#agent_auth{login = "B", timestamp = 3},
			#agent_auth{login = "C", timestamp = 5}
		],
		Three = [
			#agent_auth{login = "A", timestamp = 5},
			#agent_auth{login = "C", timestamp = 1}
		],
		Expected = [
			#agent_auth{login = "A", timestamp = 5},
			#agent_auth{login = "B", timestamp = 3},
			#agent_auth{login = "C", timestamp = 5}
		],
		?assertEqual(Expected, merge_results([{atomic, One}, {atomic, Two}, {atomic, Three}]))
	end}].

-endif.
