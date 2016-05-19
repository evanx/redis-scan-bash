
## redis-scan

### Problem

We know we must avoid `redis-cli keys '*'` especially on production servers with many keys, since that blocks other clients for a significant time e.g. more than 250ms, maybe even a few seconds. That might mean all current requests by users of your website are delayed for that time. Those will be recorded in your `slowlog` which you might be monitoring, and so alerts get triggered etc. Let's avoid that.

### Solution

Here is a Redis scanner aliased as `redis-scan` to use `SCAN` iteratively.

Extra features:
- match type of keys e.g. `@list`
- perform an "each" command on each matching key e.g. `llen`

It's brand new and untested, so please test on a disposable VM against a disposable local Redis instance, in case it trashes your Redis keys. As per the ISC license, the author disclaims any responsibility for any unfortunate events resulting from the disastrous use of this bash function ;)

Let me know any issues via Twitter (https://twitter.com/@evanxsummers) or open an issue on Github.

<img src="https://evanx.github.io/images/rquery/redis-scan-bash-featured.png">

### Examples

The default will scan all keys:
```shell
redis-scan
```
Actually, there is a `eachLimit` (default 1000) so it will only scan a 1000 keys (in batches, with sleeps inbetween), and exit with an error message "Limit reached."

If the first parameter is a number, it is taken as the database number:
```shell
redis-scan 2
```
where this scans database number `2` via `redis-cli -n 2`

We can and should use `match` to reduce the number of keys.
```shell
redis-scan 0 match 'demo:*'
```
If a parameter contains an asterisk, then `match` is assumed:
```shell
redis-scan '*'
```

#### Match type

We can filter the keys by type using an `@` prefix (rather than dashes):
```shell
redis-scan @set
```
where supported types are: `string, list, hash, set, zset.`


#### Each command

We can specify an "each" command to be executed for each key on the same Redis instance:
```shell
redis-scan 13 @hash -- hlen
```
where we use a double-dash to delimit the scan arguments and the `each` command. In this case we execute `hlen` against each key of type `hash`

Actually the script knows that `hlen` is a hashes command, and so `@hash` can be omitted:
```shell
redis-scan 13 -- hlen
```
where this will scan all keys in db `13,` and for each hashes key, print its `hlen.`

Incidently above is equivalent to the following command using `xargs`
```shell
redis-scan -n 13 @hash | xargs -n1 redis-cli -n 13 hlen
```

The following should print `set` for each, since we are filtering sets.
```shell
redis-scan @set -- type
```

Print the first five (left) elements of all list keys:
```shell
redis-scan -- lrange 0 4
```

Initial scan of matching sets:
```shell
redis-scan match 'rp:*' -- sscan 0
```
where `redis-cli sscan KEY 0` is invoked on each set key matching `rp:*`

Print hash keys:
```shell
redis-scan match 'rp:*' -- hkeys
```


#### Settings

We disable the `eachLimit` by setting it to `0` at the beginning of the command-line as follows:
```shell
eachLimit=0 redis-scan @hash match 'some keys' -- ttl
```

To force the `each` command if it dangerous e.g. `del,` we must set `commit` as follows:
```shell
commit=1 eachLimit=0 redis-scan @hash match 'some keys' -- ttl
```
where actually `commit` is not required for `ttl` but I'd rather not risk putting `del` in any examples.

Alternatively we can use `@nolimit` and `@commit` directives:
```shell
redis-scan @hash @nolimit match 'some keys' -- ttl @commit
```
where the `@` directives can be specified before or after the double-dash delimiter.

The scan sleep duration can be changed as follows:
```shell
scanSleep=1.5 redis-scan
```
where the duration is in seconds, with decimal digits allowed, as per the `sleep` shell command.


### Performance considerations

When we have a large number of matching keys, and are performing a `type` check and executing a command on each key e.g. `expire,` we could impact the server and other clients, so we mitigate this:

- by default there is an `eachLimit` of 1000 keys scanned, then exit with error code 1
- before `SCAN` with the next cursor, sleep for 5ms (hard-coded)
- additionally before next scan sleep for `scanSleep` (default duration of 250ms)
- if the slowlog length increases, double the sleep time e.g. from 250ms to 500ms
- before key type check, sleep for 5ms (hard-coded)
- sleep `eachCommandSleep` (25ms) before any specified each command is executed
- while the load average (truncated integer) is above `loadavgLimit` sleep in a loop to wait until its within this limit
- if a `loadavgKey` passed, then ascertain the current load average from that Redis key

The defaults can be overridden via the command-line, or via shell `export`

The defaults themselves are set in the script, and overridden, as follows:
```shell
local eachLimit=${eachLimit:-1000} # limit of keys to scan, pass 0 to disable
local scanSleep=${scanSleep:-.250} # sleep 250ms between each scan
local eachCommandSleep=${eachCommandSleep:-.025} # sleep 25ms between each command
local loadavgLimit=${loadavgLimit:-1} # sleep while loadavg above this threshold
local loadavgKey=${loadavgKey:-''} # ascertain loadavg from Redis key
local uptimeRemote=${uptimeRemote:-''} # ssh remote with 'uptime' command access
```

You can roughly work out how long a full scan will take by timing the run for 1000 keys, and factoring the time for the total number of keys. If it's too long, you can override the settings `scanSleep` and `eachCommandSleep` with shorter durations. However, you should monitor your system during these runs to ensure it's not too adversely affected.

If running against a remote instance:
- specify `uptimeRemote` for ssh, to determine its loadavg via `ssh $uptimeRemote uptime`
- specify `loadavgKey` to read the load average from Redis

When using `loadavgKey` you could run a minutely cron job on the Redis host:
```shell
minute=`date +%M`
while [ $minute -eq `date +%M` ]
do
  redis-cli setex 'scan:loadavg' 90 `cat /proc/loadavg | cut -d'.' -f1 | grep [0-9]` | grep -v OK
  sleep 13
done
```
where `13` is choosen since it has a factor just exceeding 60 seconds, and when the minute changes we exit.

Alternatively an ssh remote can be specified for `uptime` perhaps via an ssh forced command. The script will then ssh to the remote Redis host to get the loadavg via the `uptime` command as follows:
```shell
  ssh $uptimeRemote uptime | sed -n 's/.* load average: \([0-9]*\)\..*/\1/p'
```
#### Each commands

Currently we support the following "each" commands:
- key meta data: `type` `ttl`
- key expiry and deletion: `persist` `expire` `del`
- string: `get`
- set: `scard smembers sscan`
- zset: `zrange zrevrange zscan`
- list: `llen lrange`
- hash: `hlen hgetall hkeys hscan`

However the scan commands must have cursor `0` i.e. just the first batch

### Installation

Let's grab the repo into a `tmp` directory.
```shell
( set -e
  mkdir -p ~/tmp
  cd ~/tmp
  git clone https://github.com/evanx/redis-scan-bash
  cd redis-scan-bash
  ls -l bin
)
```

Import the logging utils and `redis-scan` scripts into our shell:
```shell
cd ~/tmp/redis-scan-bash

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

Later you can drop the following two lines into your `~/.bashrc`
```shell
. ~/redis-scan-bash/bin/bashrc.rhlogging.sh
. ~/redis-scan-bash/bin/bashrc.redis-scan.sh
```
where this assumes that the repo has been cloned to `~/redis-scan-bash`


### Troubleshooting

To enable debug logging:
```shell
export RHLEVEL=debug
```

To disable debug logging:
```shell
export RHLEVEL=info
```

### Further plans

- regex for filtering keys


### Upcoming refactor

I'll be refactoring to externalise the `RedisScan` function from `bashrc`

Then it can be included in your `PATH` or aliased in `bashrc` as follows:
```shell
alias redis-scan=~/redis-scan-bash/bin/redis-scan.sh
```

Then the script can `set -e` i.e. exit on error, with an exit trap to cleanup. Also then it can be split into multiple functions to be more readable.

It was originally intended to be a simple function that I would paste into `bashrc` but it became bigger than expected.

#### set -e

By the way, I'm a firm believer that bash scripts should `set -e` from the outset:
- we must handle nonzero returns, otherwise the script will exit
- the exit trap should alert us that the script has aborted on error
- in this case, the nonzero exit code can be `$LINENO` for debugging purposes

This enforces the good practice of handling errors, and vastly improves the robustness of bash scripts.

In development/testing:
- aborts force us to handle typical errors

In production:
- we abort before any damage is done

It's easy to reason about the state, when we know that all commands succeeded, or otherwise their nonzero returns were handled appropriately.

So for your next bash script, try `set -e` and persevere. Otherwise include a warning that your bash script is typically fragile ;)


### Contact

- https://twitter.com/@evanxsummers

### Further reading

- https://github.com/evanx/redishub
