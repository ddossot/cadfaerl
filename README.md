<pre>
               |              |    
,---.,---.,---.|---.,---.,---.|    
|    ,---||    |   ||---'|    |    
`---'`---^`---'`   '`---'`    `---'
</pre>
## In-vm non-persistent local cache for Erlang

### Features

* In-memory non-persistent
* Local gen_server backed
* No support for functional partition: start one cache per partition
* Values can optionally be 
* Optionally size-limited using a LRU strategy for removing supernumerous entries
* Simple hit/miss statistics

### Build

Compile, test and document with:

    ./rebar clean compile eunit doc
