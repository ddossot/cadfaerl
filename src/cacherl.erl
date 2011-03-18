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

-export([start_link/1, start_link/2, put/3, put_ttl/4, get/2, get/3, get_or_fetch/3]).
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
  Timestamp = timestamp(),
  ExpireAt = expire_at(Timestamp, Ttl),
  % call and not cast because we want certainty it's been stored
  gen_server:call(CacheName, {put, Key, #datum{value=Value, timestamp=Timestamp, expire_at=ExpireAt}}).

%% @doc Get a value, returning undefined if not found.
%% @spec get(CacheName::atom(), Key::term()) -> {ok, Value::term()} | undefined
get(CacheName, Key) when is_atom(CacheName) ->
  gen_server:call(CacheName, {get, Key}).

%% @doc Get a value, returning the specified default value if not found.
%% @spec get(CacheName::atom(), Key::term(), Default::term()) -> {ok, Value::term()}
get(CacheName, Key, Default) when is_atom(CacheName) ->
  case get(CacheName, Key) of 
    undefined ->
      {ok, Default};
    Value ->
      Value
  end.

%% @doc Get a value, using the provided fun/0 to fetch it if not found in cache.
%% @spec get_or_fetch(CacheName::atom(), Key::term(), Default::term()) -> {ok, Value::term()} | {error, Error::term()}
get_or_fetch(CacheName, Key, FetchFun) when is_atom(CacheName), is_function(FetchFun, 0) ->
  throw(implement_me).

%---------------------------
% Gen Server Implementation
% --------------------------
init([Name, MaximumSize]) ->
  {ok, #state{name=Name, maximum_size=MaximumSize, data_dict=dict:new(), time_tree=gb_trees:empty()}}.

handle_call({put, Key, Datum}, _From, State=#state{maximum_size=undefined, data_dict=DataDict}) ->
  {reply, ok, State#state{data_dict=put_in_dict(Key, Datum, DataDict)}};
  
handle_call({put, Key, Datum}, _From, State=#state{maximum_size=MaxSize, data_dict=DataDict, time_tree=TimeTree}) ->
  % FIXME handle MaxSize
  {reply, ok, State#state{data_dict=put_in_dict(Key, Datum, DataDict), time_tree=put_in_tree(Key, Datum, TimeTree)}};
  
handle_call({get, Key}, _From, State=#state{maximum_size=MaxSize, data_dict=DataDict, time_tree=TimeTree}) ->
  % FIXME handle expiration, refresh LRU
  Result =
    case dict:find(Key, DataDict) of
      error ->
        undefined;
      {ok, #datum{value=Value}} ->
        {ok, Value}
    end,
  {reply, Result, State};
  
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

put_in_dict(Key, Datum, DataDict) ->
  dict:store(Key, Datum, DataDict).
  
put_in_tree(Key, #datum{timestamp=Timestamp}, TimeTree) ->
  gb_trees:insert(Timestamp, Key, TimeTree).
%---------------------------
% Tests
% --------------------------
-ifdef(TEST).
% FIXME add tests
-endif.

