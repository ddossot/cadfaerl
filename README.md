
<pre>
            |\     /\                   ,, 
       _     \\   ||    _               || 
 _-_  &lt; \,  / \\ =||=  &lt; \,  _-_  ,._-_ || 
||    /-|| || ||  ||   /-|| || \\  ||   || 
||   (( || || ||  ||  (( || ||/    ||   || 
\\,/  \/\\  \\/   \\,  \/\\ \\,/   \\,  \\ 
</pre>


# CAching Datastructure For Applications in ERLang


### Features

* In-memory non-persistent cache,
* Local gen_server backed,
* No support for functional partition: start one cache per partition,
* Values can optionally be expirable,
* Support for a read-through mechanism, using a self populating function,
* Optionally size-limited using a LRU strategy for removing supernumerous entries,
* Simple hit/miss statistics.

### Limitations

* The cache doesn't regularly auto-prune expired entries.

### Build

Compile, test and document with:

    ./rebar clean compile eunit doc

### Usage

Start a cache with no size limit:

    {ok, Pid} = cadfaerl:start_link(my_cache).

Start a LRU cache with a size limit of 1000:

    {ok, Pid} = cadfaerl:start_link(my_cache, 1000).

Put and get a value (keys and values are any term):

    ok = cadfaerl:put(my_cache, my_key, "my_val").
    {ok, "my_val"} = cadfaerl:get(my_cache, my_key).
    
    undefined = cadfaerl:get(my_cache, unknown_key).
    
    {ok, "default_value"} = cadfaerl:get(my_cache, unknown_key, "default_value").
    
    ok = cadfaerl:put(my_cache, my_key, "override_val").
    {ok, "override_val"} = cadfaerl:get(my_cache, my_key).

Put a value with a TTL of 60 seconds:

    ok = cadfaerl:put_ttl(my_cache, my_key, "my_val", 60).
    {ok, "my_val"} = cadfaerl:get(my_cache, my_key).
    % after 61 seconds
    undefined = cadfaerl:get(my_cache, my_key).

Get a value, using a self-populating function in case the key is not known:

    {ok, 123} = cadfaerl:get_or_fetch(my_cache, my_key, fun() -> 123 end).
    % the fetched value is accessible like any other
    {ok, 123} = cadfaerl:get(my_cache, my_key).

Same but use a TTL of 60 seconds when self-populating the cache:

    {ok, 123} = cadfaerl:get_or_fetch(my_cache, my_key, fun() -> 123 end, 60).
    % after 61 seconds
    undefined = cadfaerl:get(my_cache, my_key).

Remove a value (or ignore if the key is unknown):

    ok = cadfaerl:remove(my_cache, my_key).

Get a cache size:

    Size = cadfaerl:size(my_cache).

Reset a cache, removing all its content:

    ok = cadfaerl:reset(my_cache).

Stop a cache:

    ok = cadfaerl:stop(my_cache).


#### Copyright 2011 - David Dossot - MIT License
