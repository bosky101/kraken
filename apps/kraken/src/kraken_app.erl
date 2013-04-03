%% @doc Callbacks for the kraken application.

-module(kraken_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for kraken.
start(_Type, _StartArgs) ->
  % Setup logging to file
  % as per sys.config for lager

  % Update the pid file if configured.
  PidFile = case application:get_env(pid_file) of
    undefined ->
      ok;
    {ok, File} ->
      file:write_file(File, os:getpid()),
      File
  end,
  {ok, Pid} = kraken_sup:start_link(),
  {ok, Pid, PidFile}.

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for kraken.
stop(PidFile) ->
  % Clear pid_file if one was used.
  case PidFile of
    undefined -> ok;
    _ -> file:delete(PidFile)
  end,
  ok.


%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

