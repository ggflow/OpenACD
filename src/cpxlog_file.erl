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
%%	The Original Code is OpenACD.
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
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc A file output backend for cpxlog.

-module(cpxlog_file).
-behaviour(gen_event).

-include_lib("kernel/include/file.hrl").
-include("log.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
	init/1,
	handle_event/2,
	handle_call/2,
	handle_info/2,
	terminate/2,
	code_change/3
]).

-record(state, {
	%level = info :: loglevels(),
	%debugmodules = [] :: [atom()],
	lasttime = erlang:localtime() :: {{non_neg_integer(), non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer(), non_neg_integer()}},
	filehandles = [] :: [{string(), any(), integer(), loglevels()}],
	color = false
}).

-type(state() :: #state{}).
-define(GEN_EVENT, true).
-include("gen_spec.hrl").

init(undefined) ->
	{'EXIT', "no logfiles defined"};
init([Files]) ->
	{ok, Color} = cpx:get_env(color_logfiles, false),
	open_files(Files, #state{color = Color}).

open_files([], State) ->
	{ok, State};
open_files([{File, LogLevel} | Tail], State) ->
	Filename = case filename:pathtype(File) of
		relative ->
			case os:getenv("OPENACD_LOG_DIR") of
				false ->
					File;
				Dir ->
					filename:join(Dir, File)
			end;
		_ ->
			File
	end,
	case file:open(Filename, [append, delayed_write]) of % buffer writes to reduce overhead
		{ok, FileHandle} ->
			{ok, FileInfo} = file:read_file_info(Filename),
			open_files(Tail, State#state{filehandles = [{Filename, FileHandle, FileInfo#file_info.inode, LogLevel} | State#state.filehandles]});
		{error, _Reason} ->
			io:format("can't open logfile ~p~n", [Filename]),
			{'EXIT', "unable to open logfile " ++ Filename}
	end.

handle_event({Level, {_, _, MicroSec} = NowTime, Module, Line, Pid, Message, Args}, State) ->
	Time = calendar:now_to_local_time(NowTime),
	Filehandles = check_filehandles(State#state.filehandles),
	case (element(3, element(1, Time)) =/= element(3, element(1, State#state.lasttime))) of
		true ->
			lists:foreach(fun({_, FH, _, _}) ->
						file:write(FH, io_lib:format("Day changed from ~p to ~p~n", [element(1, State#state.lasttime), element(1, Time)]))
			end, Filehandles);
		false ->
			ok
	end,
	Files = lists:filter(fun({_, _FH, _, LogLevel}) ->
				lists:member(Level, ?LOGLEVELS) andalso (util:list_index(Level, ?LOGLEVELS) >= util:list_index(LogLevel, ?LOGLEVELS))
		end, Filehandles),
	case Files of
		[] ->
			ok;
		List ->
			Output = io_lib:format("~s~w:~s:~s.~s [~s] ~w@~s:~w ~s~s~n", [
					colorize(Level, State#state.color),
					element(1, element(2, Time)),
					string:right(integer_to_list(element(2, element(2, Time))), 2, $0),
					string:right(integer_to_list(element(3, element(2, Time))), 2, $0),
					string:right(integer_to_list(MicroSec), 6, $0),
					string:to_upper(atom_to_list(Level)),
					Pid, Module, Line,
					io_lib:format(Message, Args),
					colorize(endcolor, State#state.color)
			]),
			[file:write(FH, Output) || {_, FH, _, _} <- List]
	end,
	{ok, State#state{lasttime = Time, filehandles = Filehandles}};
handle_event({Level, {_, _, MicroSec} = NowTime, Pid, Message, Args}, State) ->
	Time = calendar:now_to_local_time(NowTime),
	Filehandles = check_filehandles(State#state.filehandles),
	case (element(3, element(1, Time)) =/= element(3, element(1, State#state.lasttime))) of
		true ->
			lists:foreach(fun({_, FH, _, _}) ->
						file:write(FH, io_lib:format("Day changed from ~p to ~p~n", [element(1, State#state.lasttime), element(1, Time)]))
			end, Filehandles);
		false ->
			ok
	end,
	Files = lists:filter(fun({_, _FH, _, LogLevel}) ->
				lists:member(Level, ?LOGLEVELS) andalso (util:list_index(Level, ?LOGLEVELS) >= util:list_index(LogLevel, ?LOGLEVELS))
		end, Filehandles),
	case Files of
		[] ->
			ok;
		List ->
			Output = io_lib:format("~s~w:~s:~s.~s [~s] ~w ~s~s~n", [
					colorize(Level, State#state.color),
					element(1, element(2, Time)),
					string:right(integer_to_list(element(2, element(2, Time))), 2, $0),
					string:right(integer_to_list(element(3, element(2, Time))), 2, $0),
					string:right(integer_to_list(MicroSec), 6, $0),
					string:to_upper(atom_to_list(Level)),
					Pid,
					io_lib:format(Message, Args),
					colorize(endcolor, State#state.color)
			]),
			[file:write(FH, Output) || {_, FH, _, _} <- List]
	end,
	{ok, State#state{lasttime = Time, filehandles = Filehandles}};
handle_event({set_log_level, File, Level}, #state{filehandles = FH} = State) ->
	case lists:member(Level, ?LOGLEVELS) of
		true ->
			NewFH = lists:map(fun({FileName, FileHandle, FileInfo, OldLevel}) when FileName == File ->
						?NOTICE("Changed loglevel for logfile ~p from ~p to ~p", [FileName, OldLevel, Level]),
						{FileName, FileHandle, FileInfo, Level};
					(X) -> X end, FH),
			{ok, State#state{filehandles = NewFH}};
		false ->
			io:format("Invalid loglevel: ~s~n", [string:to_upper(atom_to_list(Level))]),
			{ok, State}
	end;
handle_event(_Event, State) ->
	{ok, State}.

handle_call(_Request, State) ->
	{ok, ok, State}.

handle_info(_Info, State) ->
	{ok, State}.

terminate(_Args, State) ->
	lists:foreach(fun({_, FH, _, _}) -> file:close(FH) end, State#state.filehandles),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

check_filehandles(Handles) ->
	check_filehandles(Handles, []).

check_filehandles([], Acc) ->
	lists:reverse(Acc);
check_filehandles([{Filename, Handle, Inode, Loglevel}|Tail], Acc) ->
	% check the file info to check for a rotate
	case file:read_file_info(Filename) of
		{ok, FileInfo} ->
			% compare inodes
			% XXX this won't work on win32
			case FileInfo#file_info.inode of
				Inode ->
					% file hasn't been rotated, yay
					check_filehandles(Tail, [{Filename, Handle, Inode, Loglevel} | Acc]);
				_ ->
					?INFO("~s has been replaced, reopening", [Filename]),
					case file:open(Filename, [append, raw]) of
						{ok, FileHandle} ->
							{ok, FileInfo} = file:read_file_info(Filename),
							check_filehandles(Tail, [{Filename, FileHandle, FileInfo#file_info.inode, Loglevel} | Acc]);
						{error, Reason} ->
							% this should never happen, since we were able to stat the file. Just retain the old file handle for now
							?ERROR("can't re-open logfile ~p: ~p but we could stat it?", [Filename, Reason]),
							check_filehandles(Tail, [{Filename, Handle, Inode, Loglevel} | Acc])
					end
			end;
		{error, Reason} ->
			% file probably got rotated on us
			case file:open(Filename, [append, raw]) of
				{ok, FileHandle} ->
					?INFO("~s has been moved, reopening", [Filename]),
					{ok, FileInfo} = file:read_file_info(Filename),
					check_filehandles(Tail, [{Filename, FileHandle, FileInfo#file_info.inode, Loglevel} | Acc]);
				{error, Reason} ->
					% this is pretty bad - the disk is probably full or something.
					% We have to discard this file handle now
					?ERROR("can't re-open logfile ~p: ~p", [Filename, Reason]),
					check_filehandles(Tail, Acc)
			end
	end.

colorize(_, false) ->
	"";
colorize(Level, _) ->
	colorize(Level).

colorize(debug) ->
	"\e[0;33m";
colorize(info) ->
	"";
colorize(notice) ->
	"\e[0;36m";
colorize(warning) ->
	"\e[0,35m";
colorize(endcolor) ->
	"\e[m";
colorize(_) ->
	"\e[0,31m".
