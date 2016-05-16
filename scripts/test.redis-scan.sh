
set -u -e

[ -n "$BASH" ]

. bin/bashrc.rhlogging.sh
. bin/bashrc.redis-scan.sh

scan() {
  if ! eachLimit=10 RedisScan "$@"
  then
    echo "exited with code $?. Press Enter to continue..."
    read _confirm
  fi
}

  RedisScan 'feed:*'

  scan -n 0 @hash scan match 'article:*' -- hlen
  scan -n 0 @hash scan 0 match 'article:*' -- expire 999999

  scan @hash -- hgetall
  scan 0 @hash 'article:*'
  scan 14
  scan 13 -p 6379 @hash scan -- hgetall
  scan -n 13 -p 6379 -h localhost @set -- smembers

  scan -n 0 hscan 'article:2005823:hashes'
