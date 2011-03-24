%%%
%%% @doc <b>cadfaerl</b>
%%%      In-vm non-persistent local cache for Erlang
%%%
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-module(cadfaerl).
-compile({no_auto_import,[size/1]}).
-behaviour(gen_server).

-export([start_link/1, start_link/2, stop/1,
         put/3, put_ttl/4,
         get/2, get/3,
         get_or_fetch/3, get_or_fetch_ttl/4,
         remove/2,
         size/1, reset/1, stats/1]).
         
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, clock, maximum_size, data_dict, clock_tree, miss_count, hit_count}).
-record(datum, {value, clockstamp, expire_at}).

% TODO add: cull

%---------------------------
% Public API
% --------------------------
%% @doc Start a cache with no maximum size.
%% @spec start_link(CacheName::atom()) -> {ok, Pid::pid()} | ignore | {error, Error::term()}
start_link(CacheName) when is_atom(CacheName) ->
  start_link(CacheName, undefined).
  
%% @doc Start a LRU cache with a defined maximum size.
%% @spec start_link(CacheName::atom(), MaximumSize::integer()) -> {ok, Pid::pid()} | ignore | {error, Error::term()}
start_link(CacheName, MaximumSize) when is_atom(CacheName), MaximumSize =:= undefined ; is_atom(CacheName), is_integer(MaximumSize), MaximumSize > 0 ->
  gen_server:start_link({local, CacheName}, ?MODULE, [CacheName, MaximumSize], []).

%% @doc Stop a cache.
%% @spec stop(CacheName::atom()) -> ok
stop(CacheName) when is_atom(CacheName) ->
  gen_server:cast(CacheName, stop).  

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

%% @doc Remove a value or ignore the command if the key is not present.
%% @spec remove(CacheName::atom(), Key::term()) -> ok
remove(CacheName, Key) when is_atom(CacheName) ->
  gen_server:call(CacheName, {remove, Key}).

%% @doc Size of the cache, in number of stored elements.
%% @spec size(CacheName::atom()) -> Size::integer()
size(CacheName) when is_atom(CacheName) ->
  gen_server:call(CacheName, size).  

%% @doc Reset the cache, losing all its content.
%% @spec reset(CacheName::atom()) -> ok
reset(CacheName) when is_atom(CacheName) ->
  gen_server:call(CacheName, reset).

%% @doc Get the stats as a proplist with the following keys: hit_count, miss_count.
%% @spec stats(CacheName::atom()) -> Stats::proplist()
stats(CacheName) when is_atom(CacheName) ->
  gen_server:call(CacheName, stats).  
  
%---------------------------
% Gen Server Implementation
% --------------------------
init([Name, MaximumSize]) ->
  {ok, initial_state(Name, MaximumSize)}.

handle_call({put, Key, Value, Ttl}, _From, State) ->
  {reply, ok, put_in_state(Key, Value, Ttl, State)};
  
handle_call({get, Key, Default, Ttl}, _From, State) ->
  {Result, NewState} = get_from_state(Key, Default, Ttl, State),
  {reply, Result, NewState};
  
handle_call({remove, Key}, _From, State) ->
  {reply, ok, remove_from_state(Key, State)};

handle_call(size, _From, State=#state{data_dict=DataDict}) ->
  {reply, dict:size(DataDict), State};
  
handle_call(reset, _From, State) ->
  {reply, ok, reset_state(State)};
  
handle_call(stats, _From, State=#state{miss_count=MissCount, hit_count=HitCount}) ->
  {reply, [{miss_count, MissCount}, {hit_count, HitCount}], State};
  
handle_call(Unsupported, _From, State) ->
  error_logger:error_msg("Received unsupported message in handle_call: ~p", [Unsupported]),
  {reply, {error, {unsupported, Unsupported}}, State}.

handle_cast(stop, State) ->
  {stop, normal, State};
    
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
initial_state(Name, MaximumSize) ->
  #state{name=Name, clock=0, maximum_size=MaximumSize, data_dict=dict:new(), clock_tree=gb_trees:empty(), hit_count=0, miss_count=0}.
  
reset_state(#state{name=Name, maximum_size=MaximumSize}) ->
  initial_state(Name, MaximumSize).

increment_clock(State=#state{clock=Time}) ->
  State#state{clock=Time+1}.
  
timestamp() ->
   {MegaSecs, Secs, _} = now(),
   1000000 * MegaSecs + Secs.

expire_at(_, undefined) ->
  undefined;
expire_at(Timestamp, Ttl) when is_integer(Timestamp), is_integer(Ttl) ->
  Timestamp + Ttl.

put_in_state(Key, Value, Ttl, State) ->
  Timestamp = timestamp(),
  ExpireAt = expire_at(Timestamp, Ttl),
  Datum = #datum{value=Value, expire_at=ExpireAt},
  put_datum_in_state(Key, Datum, State).

put_datum_in_state(Key, Datum, State=#state{maximum_size=undefined, data_dict=DataDict}) ->
  State#state{data_dict=dict:store(Key, Datum, DataDict)};
put_datum_in_state(Key, Datum, State=#state{maximum_size=MaximumSize, clock=Clock}) ->
  ClockStampedDatum = Datum#datum{clockstamp=Clock},
  StateRemoved = #state{data_dict=DataDict, clock_tree=ClockTree} = remove_from_state(Key, State),
  NewClockTree = gb_trees:enter(Clock, Key, ClockTree),
  
  case gb_trees:size(NewClockTree) > MaximumSize of
    false ->
      increment_clock(StateRemoved#state{data_dict=dict:store(Key, ClockStampedDatum, DataDict), clock_tree=NewClockTree});
    true ->
      % if the LRU cache is overflowing, drop the oldest entry, based on its clock value
      {_, CulledKey, CulledClockTree} = gb_trees:take_smallest(NewClockTree),
      CulledDataDict = dict:erase(CulledKey, DataDict),
      increment_clock(StateRemoved#state{data_dict=dict:store(Key, ClockStampedDatum, CulledDataDict), clock_tree=CulledClockTree})
  end.

remove_from_state(Key, State=#state{data_dict=DataDict}) ->
  remove_datum_from_state(Key, dict:find(Key, DataDict), State).
remove_datum_from_state(_, error, State) ->
  State;
remove_datum_from_state(Key, {ok, _}, State=#state{maximum_size=undefined, data_dict=DataDict}) ->
  State#state{data_dict=dict:erase(Key, DataDict)};
remove_datum_from_state(Key, {ok, #datum{clockstamp=Clockstamp}}, State=#state{data_dict=DataDict, clock_tree=ClockTree}) ->
  State#state{data_dict=dict:erase(Key, DataDict), clock_tree=gb_trees:delete(Clockstamp, ClockTree)}.

get_from_state(Key, Default, Ttl, State=#state{data_dict=DataDict}) ->
  Timestamp = timestamp(),
  
  case dict:find(Key, DataDict) of
    error ->
      handle_cache_miss(Key, Default, Ttl, State);
      
    {ok, #datum{expire_at=ExpireAt}} when Timestamp >= ExpireAt ->
      handle_cache_miss(Key, Default, Ttl, State);
    
    {ok, Datum} ->
      handle_cache_hit(Key, Datum, State)
  end.

handle_cache_miss(Key, Default, Ttl, State) when is_function(Default, 0) ->
  try
    Value = Default(),
    {{ok, Value}, put_in_state(Key, Value, Ttl, State)}
  catch
    Type:Reason ->
      {{error, {Type, Reason}}, State}
  end;
handle_cache_miss(_, Default, _, State) when Default =:= undefined ->
  {undefined, record_cache_miss(State)};
handle_cache_miss(_, Default, _, State) ->
  {{ok, Default}, record_cache_miss(State)}.

record_cache_miss(State=#state{miss_count=MissCount}) ->
  State#state{miss_count=MissCount+1}.

handle_cache_hit(_, #datum{value=Value}, State=#state{maximum_size=undefined}) ->
  {{ok, Value}, record_cache_hit(State)};
handle_cache_hit(Key, Datum=#datum{value=Value}, State) ->
  StateRefreshed = put_datum_in_state(Key, Datum, State),
  {{ok, Value}, record_cache_hit(StateRefreshed)}.

record_cache_hit(State=#state{hit_count=HitCount}) ->
  State#state{hit_count=HitCount+1}.
  
%---------------------------
% Tests
% --------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

basic_put_get_remove_stats_test() ->
  {ok, _Pid} = start_link(basic_cache),
  ?assertEqual([{miss_count, 0}, {hit_count, 0}], stats(basic_cache)),

  ?assertEqual(undefined, get(basic_cache, my_key)),
  ?assertEqual([{miss_count, 1}, {hit_count, 0}], stats(basic_cache)),

  ?assertEqual(ok, put(basic_cache, my_key, "my_val")),
  ?assertEqual([{miss_count, 1}, {hit_count, 0}], stats(basic_cache)),

  ?assertEqual({ok, "my_val"}, get(basic_cache, my_key)),
  ?assertEqual([{miss_count, 1}, {hit_count, 1}], stats(basic_cache)),

  ?assertEqual(ok, put(basic_cache, my_key, <<"other_val">>)),
  ?assertEqual([{miss_count, 1}, {hit_count, 1}], stats(basic_cache)),

  ?assertEqual({ok, <<"other_val">>}, get(basic_cache, my_key)),
  ?assertEqual([{miss_count, 1}, {hit_count, 2}], stats(basic_cache)),

  ?assertEqual(1, size(basic_cache)),
  ?assertEqual(ok, remove(basic_cache, my_key)),
  ?assertEqual(undefined, get(basic_cache, my_key)),
  ?assertEqual(0, size(basic_cache)),
  ok = stop(basic_cache).

ttl_put_get_test() ->
  {ok, _Pid} = start_link(ttl_cache),
  ?assertEqual(undefined, get(ttl_cache, my_key)),
  ?assertEqual(ok, put_ttl(ttl_cache, my_key, "my_val", 1)),
  ?assertEqual({ok, "my_val"}, get(ttl_cache, my_key)),
  timer:sleep(1100),
  ?assertEqual(undefined, get(ttl_cache, my_key)),

  ?assertEqual(ok, put_ttl(ttl_cache, my_key, "my_val2", 1)),
  ?assertEqual({ok, "my_val2"}, get(ttl_cache, my_key)),
  ?assertEqual(ok, put(ttl_cache, my_key, "my_val3")),
  timer:sleep(1100),
  ?assertEqual({ok, "my_val3"}, get(ttl_cache, my_key)),
  ?assertEqual(1, size(ttl_cache)),
  ok = stop(ttl_cache).

default_put_get_test() ->
  {ok, _Pid} = start_link(default_cache),
  ?assertEqual(undefined, get(default_cache, my_key)),
  ?assertEqual({ok, 'DEF'}, get(default_cache, my_key, 'DEF')),
  ?assertEqual(0, size(default_cache)),
  ?assertEqual(ok, put(default_cache, my_key, "my_val")),
  ?assertEqual({ok, "my_val"}, get(default_cache, my_key, 'DEF')),

  ?assertEqual(ok, put_ttl(default_cache, my_key, "my_val2", 1)),
  ?assertEqual({ok, "my_val2"}, get(default_cache, my_key, 'DEF')),
  timer:sleep(1100),
  ?assertEqual({ok, 'DEF'}, get(default_cache, my_key, 'DEF')),
  ok = stop(default_cache).

get_or_fetch_test() ->
  {ok, _Pid} = start_link(fetch_cache),
  ?assertEqual({ok, 123}, get_or_fetch(fetch_cache, my_key, fun() -> 123 end)),
  ?assertEqual({ok, 123}, get(fetch_cache, my_key)),
  ?assertEqual({error, {throw, foo}}, get_or_fetch(fetch_cache, other_key, fun() -> throw(foo) end)),
  ?assertEqual(undefined, get(fetch_cache, other_key)),
  ok = stop(fetch_cache).

get_or_fetch_ttl_test() ->
  {ok, _Pid} = start_link(fetch_ttl_cache),
  FetchFun = fun() -> now() end,
  {ok, Val1} = get_or_fetch_ttl(fetch_ttl_cache, my_key, FetchFun, 1),
  ?assertEqual({ok, Val1}, get_or_fetch_ttl(fetch_ttl_cache, my_key, FetchFun, 1)),
  timer:sleep(1100),
  {ok, Val2} = get_or_fetch_ttl(fetch_ttl_cache, my_key, FetchFun, 1),
  ?assert(Val1 =/= Val2),
  ok = stop(fetch_ttl_cache).

lru_cache_test() ->
  {ok, _Pid} = start_link(lru_cache, 2),
  ?assertEqual(ok, put(lru_cache, my_key1, "my_val1")),
  ?assertEqual(1, size(lru_cache)),
  ?assertEqual(ok, put(lru_cache, my_key2, "my_val2")),
  ?assertEqual(2, size(lru_cache)),
  ?assertEqual({ok, "my_val1"}, get(lru_cache, my_key1)),
  ?assertEqual(ok, put(lru_cache, my_key3, "my_val3")),
  ?assertEqual(2, size(lru_cache)),
  ?assertEqual({ok, "my_val1"}, get(lru_cache, my_key1)),
  ?assertEqual(undefined, get(lru_cache, my_key2)),
  ?assertEqual({ok, "my_val3"}, get(lru_cache, my_key3)),
  ok = stop(lru_cache).
  
reset_test() ->
  InitialState = initial_state(my_name, 123),
  ChangedState = InitialState#state{clock=25},
  ?assertEqual(InitialState, reset_state(ChangedState)),
  
  {ok, _Pid} = start_link(reset_cache),
  ?assertEqual(ok, put(reset_cache, my_key, "my_val")),
  ?assertEqual({ok, "my_val"}, get(reset_cache, my_key)),
  ?assertEqual(1, size(reset_cache)),
  ?assertEqual([{miss_count, 0}, {hit_count, 1}], stats(reset_cache)),

  ?assertEqual(ok, reset(reset_cache)),

  ?assertEqual([{miss_count, 0}, {hit_count, 0}], stats(reset_cache)),
  ?assertEqual(undefined, get(reset_cache, my_key)),
  ?assertEqual(0, size(reset_cache)),
  ok = stop(reset_cache).

-endif.

