%%%
%%% @doc <b>cacherl</b>
%%%      In-vm non-persistent local cache for Erlang
%%%
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-module(cacherl).
-behaviour(gen_server).

-export([start_link/1, start_link/2, put/3, put_ttl/4, get/2, get/3, get_or_fetch/3, get_or_fetch_ttl/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, maximum_size, data_dict, time_tree}).
-record(datum, {value, timestamp, expire_at}).

% FIXME add basic stats

%---------------------------
% Public API
% --------------------------
%% @doc Start a cache with not maximum size.
%% @spec start_link(CacheName::atom()) -> {ok, Pid::pid()} | ignore | {error, Error::term()}
start_link(CacheName) when is_atom(CacheName) ->
  start_link(CacheName, undefined).
  
%% @doc Start a LRU cache with a defined maximum size.
%% @spec start_link(CacheName::atom(), MaximumSize::integer()) -> {ok, Pid::pid()} | ignore | {error, Error::term()}
start_link(CacheName, MaximumSize) when is_atom(CacheName), MaximumSize =:= undefined orelse is_integer(MaximumSize) ->
  gen_server:start_link({local, CacheName}, ?MODULE, [CacheName, MaximumSize], []).

%% @doc Put a non-expirabled value.
%% @spec put(CacheName::atom(), Key::term(), Value::term()) -> ok
put(CacheName, Key, Value) when is_atom(CacheName) ->
  put_ttl(CacheName, Key, Value, undefined).

%% @doc Put an expirable value with a time to live in seconds.
%% @spec put_ttl(CacheName::atom(), Key::term(), Value::term(), Ttl::integer()) -> ok
put_ttl(CacheName, Key, Value, Ttl) when is_atom(CacheName), Ttl =:= undefined orelse is_integer(Ttl) ->
  % call and not cast because we want certainty it's been stored
  gen_server:call(CacheName, {put, Key, Value, Ttl}).

%% @doc Get a value, returning undefined if not found.
%% @spec get(CacheName::atom(), Key::term()) -> {ok, Value::term()} | undefined
get(CacheName, Key) when is_atom(CacheName) ->
  get(CacheName, Key, undefined).

%% @doc Get a value, using the provided fun/0 to fetch it if not found in cache.
%% @spec get_or_fetch(CacheName::atom(), Key::term(), Default::term()) -> {ok, Value::term()} | {error, Error::term()}
get_or_fetch(CacheName, Key, FetchFun) when is_atom(CacheName), is_function(FetchFun, 0) ->
  get(CacheName, Key, FetchFun).

%% @doc Get a value, using the provided fun/0 to fetch it if not found in cache, storing the new value with the provided Ttl.
%% @spec get_or_fetch_ttl(CacheName::atom(), Key::term(), Default::term(), Ttl::integer()) -> {ok, Value::term()} | {error, Error::term()}
get_or_fetch_ttl(CacheName, Key, FetchFun, Ttl) when is_atom(CacheName), is_function(FetchFun, 0), Ttl =:= undefined orelse is_integer(Ttl) ->
  do_get(CacheName, Key, FetchFun, Ttl).

%% @doc Get a value, returning the specified default value if not found.
%% @spec get(CacheName::atom(), Key::term(), Default::term()) -> {ok, Value::term()}
get(CacheName, Key, Default) when is_atom(CacheName) ->
  do_get(CacheName, Key, Default, undefined).

do_get(CacheName, Key, Default, Ttl) ->
  gen_server:call(CacheName, {get, Key, Default, Ttl}).
  
%---------------------------
% Gen Server Implementation
% --------------------------
init([Name, MaximumSize]) ->
  {ok, #state{name=Name, maximum_size=MaximumSize, data_dict=dict:new(), time_tree=gb_trees:empty()}}.

handle_call({put, Key, Value, Ttl}, _From, State) ->
  {reply, ok, put_in_state(Key, Value, Ttl, State)};
  
handle_call({get, Key, Default, Ttl}, _From, State) ->
  {Result, NewState} = get_from_state(Key, Default, Ttl, State),
  {reply, Result, NewState};
  
handle_call(Unsupported, _From, State) ->
  error_logger:error_msg("Received unsupported message in handle_call: ~p", [Unsupported]),
  {reply, {error, {unsupported, Unsupported}}, State}.

handle_cast(Unsupported, State) ->
  error_logger:error_msg("Received unsupported message in handle_cast: ~p", [Unsupported]),
  {noreply, State}.

handle_info(Unsupported, State) ->
  error_logger:error_msg("Received unsupported message in handle_info: ~p", [Unsupported]),
  {noreply, State}.

terminate(_, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%---------------------------
% Support Functions
% --------------------------

timestamp() ->
   {MegaSecs, Secs, _} = now(),
   1000000 * MegaSecs + Secs.

expire_at(_, undefined) ->
  undefined;
expire_at(Timestamp, Ttl) when is_integer(Timestamp), is_integer(Ttl) ->
  Timestamp + Ttl.

put_in_state(Key, Value, Ttl, State=#state{maximum_size=MaxSize, data_dict=DataDict, time_tree=TimeTree}) ->
  Timestamp = timestamp(),
  ExpireAt = expire_at(Timestamp, Ttl),
  Datum = #datum{value=Value, timestamp=Timestamp, expire_at=ExpireAt},
  
  case MaxSize of
    undefined ->
      State#state{data_dict=put_in_dict(Key, Datum, DataDict)};
    MaxSize ->
      % FIXME handle MaxSize
      State#state{data_dict=put_in_dict(Key, Datum, DataDict), time_tree=put_in_tree(Key, Datum, TimeTree)}
  end.
  
put_in_dict(Key, Datum, DataDict) ->
  dict:store(Key, Datum, DataDict).
  
put_in_tree(Key, #datum{timestamp=Timestamp}, TimeTree) ->
  gb_trees:enter(Timestamp, Key, TimeTree).

get_from_state(Key, Default, Ttl, State=#state{data_dict=DataDict}) ->
  Timestamp = timestamp(),
  
  case dict:find(Key, DataDict) of
    error ->
      handle_cache_miss(Key, Default, Ttl, State);
      
    {ok, #datum{expire_at=ExpireAt}} when Timestamp >= ExpireAt ->
      % FIXME delete from state
      handle_cache_miss(Key, Default, Ttl, State);
    
    {ok, #datum{value=Value}} ->
      {{ok, Value}, State}
  end.

handle_cache_miss(Key, Default, Ttl, State) when is_function(Default, 0) ->
  % FIXME must catch exceptions and return {error, _}
  Value = Default(),
  {{ok, Value}, put_in_state(Key, Value, Ttl, State)};
handle_cache_miss(_, Default, _, State) when Default =:= undefined ->
  {undefined, State};
handle_cache_miss(_, Default, _, State) ->
  {{ok, Default}, State}.
  
%---------------------------
% Tests
% --------------------------
-ifdef(TEST).
% FIXME add tests
-endif.

