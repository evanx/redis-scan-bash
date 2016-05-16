
## redis-scan

We know we must avoid `redis-cli keys '*'` especially on production servers, since this locks up Redis for the duration.

Here is a Redis scanner intended for `~/.bashrc` aliased as `redis-scan`

It's brand new and untested, so please test on a disposable VM against a disposable local Redis instance, in case it trashes your Redis keys. As per the ISC license, the author disclaims any responsibility for any unfortunate events resulting from the disastrous use of this bash function ;)

### Examples

By default it will scan through all keys using `SCAN` (with a cursor), sleeping for `sleep` (default 250ms) before fetching the next batch, so that we don't hog Redis and give other clients a chance, which is especially important on production machines - although this script is not recommended for any production environments (yet).

Incidently, it will also sleep while the current load average is above the default limit (1) so that what we are doing doesn't further overload our machine.

However when accessing a remote Redis instance via `-h` we might be clobbering that. So the script checks the `slowlog` length between batches and if it increases, then sleeps some more to offer some relief.

The default will scan all keys:
```shell
redis-scan
```

If the first parameter is a number, it is taken as the database number:
```shell
redis-scan 2
```
where this scans database number `2` via `redis-cli -n 2`

We can use `match`
```shell
redis-scan 0 match '*'
```
If a parameter contains an asterisk, then `match` is assumed:
```shell
redis-scan '*'
```

We can filter the keys by type using an asterisk notation:
```shell
redis-scan @set
```
where supported types are: `string, list, hash, set, zset.`

We can specify an "each" command to be executed for each key on the same Redis instance:
```shell
redis-scan @hash -- hlen
```
where we use "--" to delimit the scan arguments and the `each` command. In this case we execute `hlen` against each key of type `hash`

Incidently above is equivalent to the following command using `xargs`
```shell
redis-scan -n 0 @hash | xargs -n1 redis-cli -n 0 hlen
```

The following should print "set" for each, since we are filtering sets.
```shell
redis-scan @set -- type
```

To disable the `eachLimit` and actually perform the `each` command if it dangerous e.g. `del`
```shell
commit=1 eachLimit=0 redis-scan @hash match 'some keys' -- ttl
```
where `echo` is a psuedo command to just echo the key.

Alternatively we can use `@nolimit` and `@commit` directives:
```shell
redis-scan @hash @nolimit match 'some keys' -- ttl @commit
```
where the `@` directives can be specified before or after the "--" delimiter.

### Implementation

See: https://github.com/evanx/rquery/tree/master/bin

Let's grab the repo into a `tmp` directory.
```shell
( set -e
  mkdir -p ~/tmp
  cd ~/tmp
  git clone https://github.com/evanx/rquery
  cd rquery
  ls -l bin
)
```

Import the logging utils and `redis-scan` scripts into our shell:
```shell
. bin/bashrc.rhlogging.sh
. bin/bashrc.redis-scan.sh
```
Now we can try `redis-scan` in this shell:
```shell
redis-scan
redis-scan @set
redis-scan @hash match '*'
redis-scan @set -- ttl
```

https://twitter.com/@evanxsummers
