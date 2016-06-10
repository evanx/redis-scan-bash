#/bin/bash 

set -u -e

RHDIR=${RHDIR-$HOME/redis-scan-bash}
. $RHDIR/bin/rhlogging.sh

RedisScan_help() {
  rhinfo "Example commands:"
  rhinfo "redis-scan '*' # scan all keys"
  rhinfo "redis-scan @1 '*' -- scard # scan all on db1, if set then scard" 
  rhinfo "redis-scan @1 'demo:*' -- hgetall # if hash, then hgetall" 
  rhcomment "See https://github.com/evanx/redis-scan-bash"
}

eachLimit=${eachLimit-1000} # limit of keys to scan, pass 0 to disable
scanSleep=${scanSleep-0.250} # sleep 250ms between each scan
eachCommandSleep=${eachCommandSleep-0.025} # sleep 25ms between each command
loadavgLimit=${loadavgLimit-1} # sleep while local loadavg above this threshold
loadavgKey=${loadavgKey-} # ascertain loadavg from Redis key on target instance
uptimeRemote=${uptimeRemote-} # ascertain loadavg via ssh to remote Redis host

formatJson=${RH_formatJson-1} # use python to format
colorJson=${RH_colorJson-1} # use pygmentize to colorise
rhdebug formatJson=${formatJson} colorJson=${colorJson}

commit=${commit-0} # when each commands specified, default is dry run if no @commit cli-param
quiet=${quiet-0} # be less noisy

# ensure user/process specific tmp dir 

RHDIR=${RHDIR-~/redis-scan-bash} # or ~/redishub, for rhlogging
. $RHDIR/bin/rhlogging.sh

RedisScan_clean() {
  rhdebug 'clean' ~/.redis-scan/tmp
  if [ ! -d ~/.redis-scan/tmp ]
  then
    rherror "No directory: ~/.redis-scan/tmp"
  else
    if [ ! -f ~/.redis-scan/tmp/$$.run ]
    then
      rherror "No PID file: ~/.redis-scan/tmp/$$.run"
    else
      rm ~/.redis-scan/tmp/$$*
    fi
    local findCount=`find ~/.redis-scan/tmp -mtime +7 -type f | wc -l`
    rhdebug "Found $findCount old files in ~/.redis-scan/tmp."
    if [ $findCount -gt 0 ]
    then
      rhdebug "Running find and delete for older than 7 days:"
      rhdebug "find ~/.redis-scan/tmp -mtime +7 -type f -delete"
      find ~/.redis-scan/tmp -mtime +7 -type f -delete
    fi
  fi
}

trap_exit() {
  #rhdebug "line $1: trap_exit"
  RedisScan_clean
}

trap_err() {
  rhdebug "line $1: trap_error"
}

trap 'trap_exit $LINENO' EXIT
trap 'trap_err $LINENO' ERR

# env

if [ ! -d ~/.redis-scan/tmp ]
then
  rhinfo "Creating tmp dir: ~/.redis-scan/tmp"
  mkdir -p ~/.redis-scan/tmp
fi
tmp=~/.redis-scan/tmp/$$
rhdebug "tmp $tmp" $$
echo $$ > $tmp.run

which python > /dev/null 
which_python=$?
which bc > /dev/null 
which_bc=$?
if [ $which_python -ne 0 -a $which_bc -ne 0 ]
then
  rhabort ENV $LINENO "Please install 'bc' or 'python'"
fi

echo '{}' | pygmentize -l json 2>/dev/null >/dev/null || rhdebug 'Install pygmentize to colorise JSON'
try_pygmentize=$?

# static

keyScanCommands='sscan zscan hscan'
scanCommands='scan sscan zscan hscan'
matchTypes='string set zset list hash any' # 'any' for testing
eachCommands='type ttl persist expire del length value' # 'length' for strlen/llen/hlen/scard/zcard
safeEachCommands='type ttl get scard smembers zcard llen hlen hgetall hkeys hvals sscan zscan lrange length value'
eachArgsCommands='expire lrange sscan hscan zrevrange zrange'
declare -A typeEachCommands
typeEachCommands['string']='get'
typeEachCommands['list']='llen lrange'
typeEachCommands['hash']='hlen hgetall hkeys hvals hscan'
typeEachCommands['set']='scard smembers sscan'
typeEachCommands['zset']='zcard zrevrange zrange zscan'
keyTypes="string list hash set zset"
for keyType in $keyTypes
do
  eachCommands="$eachCommands ${typeEachCommands[$keyType]}"
done
rhdebug "eachCommands $eachCommands"

# variables

stime=`date +%s`
cursor=${cursor-0}
scanCount=${scanCount-0}
redisArgs=''
matchType=''
eachCommand=''
eachArgs=''
scanCommand='scan'
scanKey=''
keyCount=0
cursorCount=0

declare -a scanArgs=()

rhdebug "sleep: $scanSleep, loadavgLimit: $loadavgLimit, eachLimit: $eachLimit, args:" "$@"

RedisScan_args() { # scan command with sleep between iterations
  rhdebug "redis-scan args: ${*} (limit $eachLimit keys, sleep ${scanSleep})"
  # check initial arg for dbn
  if [ $# -eq 0 ]
  then
    scanCommand='scan'
  else
    if echo "$1" | grep -q "^[0-9][0-5]\{0,1\}$"
    then
      rhabort PARAM $LINENO 'Use @dbn for the db number'
    elif echo "$1" | grep -q "^@[0-9][0-5]\{0,1\}$"
    then
      local dbn=`echo "$1" | tail -c+2`
      shift
      redisArgs=" -n $dbn"
      rhinfo "dbn $dbn"
    fi
  fi
  # iterate redis args until scan args
  while [ $# -gt 0 ]
  do
    local arg="$1"
    shift
    if RedisScan_argsEach "$arg" 
    then
      rhdebug 'redisArgs common $arg'
    elif printf '%s' "$arg" | grep -qi '^scan$'
    then
      if [ $# -gt 0 ]
      then
        if echo "$1" | grep -q '^[0-9][0-9]*$'
        then
          cursor=$1
          shift
        fi
      fi
      break
    elif printf '%s' "$arg" | grep -qi 'scan$'
    then
      scanCommand=$arg
      if [ $# -eq 0 ]
      then
        rhabort PARAM $LINENO "Missing key for $scanCommand"
      fi
      scanKey=" $1"
      rhdebug "scanKey$scanKey"
      shift
      if [ $# -gt 0 ]
      then
        if echo "$1" | grep -q '^[0-9][0-9]*$'
        then
          cursor=$1
          shift
        fi
      fi
      break
    elif printf '%s' "$arg" | grep -qi '^match$'
    then
      if [ $# -eq 0 ]
      then
        rhabort PARAM $LINENO "missing match pattern"
      fi
      local pattern="$1"
      shift
      scanArgs+=("$arg" "$pattern")
      rhdebug scanArgs "${scanArgs[@]}"
      break
    elif printf '%s' "$arg" | grep -q '*'
    then
      scanArgs+=('match' "$arg")
      rhdebug scanArgs "${scanArgs[@]}"
      break
    elif printf '%s' "$arg" | grep -qi '^count$'
    then
      if [ $# -eq 0 ]
      then
        rhabort PARAM $LINENO "Missing count number after 'count'"
      fi
      if echo "$1" | grep -qv '^[1-9][0-9]*$'
      then
        rhabort PARAM $LINENO "Invalid count number: $1"
      fi
      scanCount="$1"
      shift
      scanArgs+=("$arg" "$scanCount")
      rhdebug scanArgs "${scanArgs[@]}"
      break
    elif [ "$arg" = '--' ]
    then
      eachCommand="$1"
      if ! shift
      then
        rhabort PARAM $LINENO "missing each command [$@]"
      fi
      rhdebug "each $eachCommand [$@]"
      break
    else
      redisArgs="$redisArgs $arg"
    fi
  done
  rhdebug "redisArgs [$redisArgs]"
  # check scanCommand
  if [ ${#scanCommand} -eq 0 ]
  then
    rhabort PARAM $LINENO "Missing scan command: $scanCommands"
  fi
  if echo "$scanCommand" | grep -qvi "scan"
  then
    rhabort PARAM $LINENO "Invalid scan command: $scanCommand. Expecting one of: $scanCommands"
  fi
  # handle scan args
  if [ ${#eachCommand} -eq 0 ]
  then
    # iterate scanArgs until '--'
    while [ $# -gt 0 ]
    do
      local arg="$1"
      shift
      if RedisScan_argsEach "$arg" 
      then
        rhdebug 'scanArgs common $arg'
      elif [ "$arg" = '--' ]
      then
        if [ $# -eq 0 ]
        then
          rhabort PARAM $LINENO "Missing 'each' command after '--' delimiter"
        fi
        eachCommand="$1"
        shift
        rhdebug "eachCommand [$eachCommand]"
        break
      elif printf '%s' "$arg" | grep -q '*'
      then
        scanArgs+=('match' "$arg")
      else
        scanArgs+=("$arg")
      fi
    done
  fi
  # check scan args
  rhdebug "scanArgs ${#scanArgs[@]}"
  if [ ${#scanArgs[@]} -eq 0 ]
  then
    rhdebug 'scanArgs empty'
  else
    rhdebug "scanArgs [${scanArgs[@]}]"
  fi
  rhdebug "eachCommand [$eachCommand]"
  if [ ${#eachCommand} -gt 0 ]
  then
    RedisScan_argsEachCommand "$@"
    RedisScan_eachConfirm
  fi
  RedisScan_scan
}

RedisScan_argsEachCommand() {
  if echo " $eachCommands " | grep -qv " $eachCommand "
  then
    rhabort PARAM $LINENO "Invalid each command: $eachCommand. Try one of: $eachCommands"
  fi
  if echo " $eachArgsCommands " | grep -q " $eachCommand "
  then
    if [ $# -eq 0 ]
    then
      rhabort PARAM $LINENO "Command (each) missing args: $eachCommand"
    fi
  fi
  if [ ${#matchType} -eq 0 ]
  then
    for keyType in $keyTypes
    do
      rhdebug "eachCommand: $eachCommand, $keyType: ${typeEachCommands[$keyType]}"
      if echo " ${typeEachCommands[$keyType]} " | grep -q " $eachCommand "
      then
        matchType=$keyType
        break
      fi
    done
    if [ $# -eq 0 ] 
    then
      rhdebug 'each args empty'
    else
      RedisScan_argsEachCommandLoop "$@" 
    fi
  fi
}

RedisScan_argsEachCommandLoop() {
  while [ $# -gt 0 ]
  do
    local arg="$1"
    shift
    if RedisScan_argsEach "$arg"
    then
      rhdebug "eachArgs common $arg"
    elif printf '%s' "$arg" | grep -q '^-'
    then
      rhabort PARAM $LINENO "Unsupported each arg: $arg"
    else
      eachArgs="$eachArgs $arg"
    fi
  done
}

RedisScan_argsEach() {
  local arg="$1"
  rhdebug "arg $arg"
  if [[ "$arg" =~ ^@ ]]
  then
    local argt=`echo "$arg" | tail -c+2`
    if [ -z "$argt" ]
    then
      rhabort PARAM $LINENO "Empty directive"
    elif [ $argt = 'quiet' ]
    then
      quiet=1
    elif [ $argt = 'commit' ]
    then
      commit=1
    elif [ $argt = 'nolimit' ]
    then
      eachLimit=0
    else
      matchType="$argt"
      if [ $matchType = 'hashes' ]
      then
        matchType=hash
      elif echo "$matchTypes" | grep -qv "$matchType"
      then
        rhabort PARAM $LINENO "Invalid specified key type: $matchType. Expecting one of: $matchTypes"
      fi
      rhdebug "matchType $matchType"
    fi
  else 
    return 63
  fi
}

RedisScan_eachConfirm() {
  if [ $quiet -eq 1 -a $commit -eq 0 ] 
  then
    return 
  fi
  if [ ${#matchType} -gt 0 ]
  then
    rhinfo "@$matchType eachLimit=$eachLimit commit=$commit scanSleep=$scanSleep loadavgLimit=$loadavgLimit"
  else
    rhinfo "eachLimit=$eachLimit commit=$commit scanSleep=$scanSleep loadavgLimit=$loadavgLimit"
  fi
  rhwarn 'each:' redis-cli$redisArgs $eachCommand KEY$eachArgs
  if [ $commit -eq 1 ]
  then
    rherror "WARNING: each command '$eachCommand' will be executed on each scanned key"
    if echo " $safeEachCommands " | grep -qv " $eachCommand "
    then
      rherror 'Press Ctrl-C to abort, enter to continue'
      read _confirm
    fi
  elif echo " $safeEachCommands " | grep -qv " $eachCommand "
  then
    rhwarn "DRY RUN: each commands '$eachCommand' are not executed, only displayed. Later, try @commit"
    rhwarn 'Press Ctrl-C to abort, enter to continue'
    read _confirm
  fi
}

RedisScan_scanEach() {
  for key in `tail -n +2 $tmp.scan`
  do
    if [ ${#matchType} -gt 0 ]
    then
      sleep .005 # hard-coded minimum sleep, also $scanSleep below
      local keyType=`redis-cli$redisArgs type $key`
      if [ $matchType != 'any' -a $keyType != $matchType ]
      then
        #rhdebug "ignore $key type $keyType, not $matchType"
        continue
      fi
    fi
    if [ ${#eachCommand} -eq 0 ]
    then
      echo $key
    elif [ $eachCommand = 'echo' ]
    then
      echo $key
    else
      if [ $quiet = 0 ]
      then
        if [ $eachCommand = 'length' ]
        then
          rhdebug "redis-cli args: $redisArgs (print length)"
        elif [ $eachCommand = 'value' ]
        then
          rhdebug "redis-cli args: $redisArgs (print value)"
        else
          rhinfo redis-cli$redisArgs $eachCommand $key$eachArgs
        fi
      fi
      if [ $commit -eq 1 ] || echo " $safeEachCommands " | grep -q " $eachCommand "
      then
        RedisScan_scanEachExecute "$key"
      fi
    fi
  done
}

RedisScan_formatJsonValue() {
  local value="$1"
  local formattedValue=''
  if echo "$value" | head -1 | grep -q '^{\|^\[' && 
    echo "$value" | tail -1 | grep -q '}\s*$\|\]\s*$'
  then
    #rhdebug "json formatJson=[$formatJson] colorJson=[$colorJson] pygmentize=[$try_pygmentize]"
    if [ "$formatJson" = 1 -a ${#formattedValue} -eq 0 -a $which_python -eq 0 ]
    then
      local json=`echo "$value" | python -mjson.tool 2>/dev/null || echo ''`
      if [ ${#json} -gt 0 ]
      then
        if [ "$colorJson" = 1 -a "$try_pygmentize" -eq 0 ]
        then
          formattedValue=`echo "$json" | pygmentize -l json 2>/dev/null || echo ''`
        else
          formattedValue="$json"
        fi
      fi
    fi
  fi
  if [ ${#formattedValue} -gt 0 ] 
  then
    echo "$formattedValue"
  else
    echo "$value"
  fi
}

RedisScan_scanEachExecute() { # key # $tmp.scan
  local key="$1"
  sleep $eachCommandSleep
  local actualEachCommand="$eachCommand"
  if [ "$eachCommand" = "length" ]
  then
    local type=`redis-cli$redisArgs type "$key" | grep '^[a-z]*$' || echo ''`
    local lengthCommand=`RedisScan_lengthCommand "$type"`
    if [ ${#lengthCommand} -gt 0 ]
    then
      [ $quiet -eq 0 ] && rhinfo "redis-cli$redisArgs $lengthCommand $key"
      redis-cli$redisArgs $lengthCommand $key 
    fi
    return
  elif [ "$eachCommand" = "value" ]
  then
    local type=`redis-cli$redisArgs type "$key" | grep '^[a-z]*$' || echo ''`
    local valueCommand=`RedisScan_valueCommand "$type" "$key" "$eachArgs"`
    if [ ${#valueCommand} -eq 0 ]
    then
      return
    else
      actualEachCommand=`echo "$valueCommand" | cut -d' ' -f1`
      [ $quiet -eq 0 ] && rhinfo "redis-cli$redisArgs $valueCommand"
      redis-cli$redisArgs $valueCommand > $tmp.each
    fi
  else
    redis-cli$redisArgs $eachCommand $key$eachArgs > $tmp.each
  fi
  if [ $? -ne 0 ] || head -1 $tmp.each | grep -q '^(error)\|^WRONGTYPE\|^Unrecognized option\|^Could not connect'
  then
    cat $tmp.each
    rhabort APP $LINENO
  fi
  if [ "$actualEachCommand" = "hgetall" ]
  then
    for key in `cat $tmp.each | sed -n -e '1~2p'`
    do
      value=`cat $tmp.each | grep "^${key}$" -A1 | tail -1`
      value=`RedisScan_formatJsonValue "$value"`
      rhprop $key "$value"
    done
  elif [ $formatJson = 1 ]
  then
    value=`cat $tmp.each`
    value=`RedisScan_formatJsonValue "$value"`
    echo "$value"
  else
    cat $tmp.each
  fi
}

RedisScan_valueCommand() {
  local type="$1"
  local key="$2"
  local args="$3"
  if [ "$type" = 'string' ]
  then
    echo "get $key"
  elif [ "$type" = 'list' ]
  then
    echo "lrange $key 0 10"
  elif [ "$type" = 'set' ]
  then
    echo "sscan $key 0"
  elif [ "$type" = 'zset' ]
  then
    echo "zscan $key 0"
  elif [ "$type" = 'hash' ]
  then
    if [ ${#args} -gt 0 ]
    then
      rhdebug "value $type  $key $type $args"
      echo "hget $key $args"
    else
      echo "hgetall $key"
    fi
  else
    echo ''
  fi
}

RedisScan_lengthCommand() {
  local type="$1"
  if [ "$type" = 'string' ]
  then
    echo 'strlen'
  elif [ "$type" = 'list' ]
  then
    echo 'llen'
  elif [ "$type" = 'set' ]
  then
    echo 'scard'
  elif [ "$type" = 'zset' ]
  then
    echo 'zcard'
  elif [ "$type" = 'hash' ]
  then
    echo 'hlen'
  else
    echo ''
  fi
}

RedisScan_scan() {
  local message="scan: redis-cli$redisArgs $scanCommand$scanKey $cursor"
  if [ ${#scanArgs[@]} -gt 0 ]
  then
    message="$message ${scanArgs[@]}"
  fi
  if [ $quiet -eq 1 ]
  then
    rhdebug "$message"
  else
    rhinfo "$message"
  fi    
  local slowlogLen=`redis-cli$redisArgs slowlog len`
  if ! [[ "$slowlogLen" =~ ^[0-9][0-9]*$ ]]
  then
     rhabort PARAM $LINENO "redis-cli$redisArgs slowlog len"
  fi
  rhdebug "redis-cli$redisArgs slowlog len # $slowlogLen"
  while [ true ]
  do
    sleep .005 # hard-coded minimum scan sleep, also $scanSleep below
    if [ $eachLimit -gt 0 -a $keyCount -gt $eachLimit ]
    then
      rherror "Limit reached: eachLimit $eachLimit"
      RedisScan_clean
      return 60
    fi
    if [ ! -f $tmp.run ]
    then
      rhabort APP $LINENO "Run file deleted: $tmp.run"
    fi
    if cat $tmp.run | grep -qv "^${$}$"
    then
      rhabort APP $LINENO "Run file inconsistent PID: $tmp.run `cat $tmp.run` $$"
    fi
    local scanArgsString=''
    if [ ${#scanArgs[@]} -eq 0 ]
    then
      redis-cli$redisArgs $scanCommand$scanKey $cursor > $tmp.scan
      if [ $? -ne 0 ] || head -1 $tmp.scan | grep -qv '^[0-9][0-9]*$'
      then
        rhabort APP $LINENO "redis-cli$redisArgs $scanCommand$scanKey $cursor"
      fi
    else
      scanArgsString="${scanArgs[@]}"
      redis-cli$redisArgs $scanCommand$scanKey $cursor "${scanArgs[@]}" > $tmp.scan
      if [ $? -ne 0 ] || head -1 $tmp.scan | grep -qv '^[0-9][0-9]*$'
      then
        rhabort APP $LINENO "redis-cli$redisArgs $scanCommand$scanKey $cursor $scanArgsString"
      fi
    fi
    cursor=`head -1 $tmp.scan`
    keyCount=$[ $keyCount + `cat $tmp.scan | wc -l` - 1 ]
    rhdebug keyCount $keyCount
    if [ $cursorCount -eq 0 -o $[ $cursorCount % 10 ] -eq 0 ]
    then
      rhdebug "redis-cli$redisArgs $scanCommand $cursor $scanArgsString # cursor $cursor, keys $keyCount, @$matchType each [$eachCommand]"
    fi
    cursorCount=$[ $cursorCount + 1 ]
    if [ ${#matchType} -eq 0 -a ${#eachCommand} -eq 0 ]
    then
      if [ `tail -n +2 $tmp.scan | sed '/^$/d' | wc -l` -gt 0 ]
      then
        tail -n +2 $tmp.scan
      fi
    else
      RedisScan_scanEach
    fi
    if [ $cursor -eq 0 ]
    then
      rhinfo 'OK'
      break
    fi
    sleep $scanSleep # sleep to alleviate the load on this (local) server
    # check slowlog
    local _slowlogLen=`redis-cli$redisArgs slowlog len`
    if ! echo "$_slowlogLen" | grep -q '^[0-9][0-9]*$'
    then
      rhabort APP $LINENO "redis-cli$redisArgs slowlog len"
    fi
    if [ $_slowlogLen -ne $slowlogLen ]
    then
      if which bc > /dev/null
      then
        scanSleep=`echo "scale=3; 2*$scanSleep" | bc`
      elif which python > /dev/null
      then
        scanSleep=`python -c "print 2*$scanSleep"`
      fi
      slowlogLen=$_slowlogLen
      rhwarn "slowlog length was $slowlogLen, now $_slowlogLen, scanSleep now $scanSleep"
      sleep 5 # sleep
    fi
    if cat /proc/loadavg | grep -q "^[0-${loadavgLimit}]\."
    then
      if [ -n "$loadavgKey" ]
      then
        while [ 1 ]
        do
          local loadavg=`redis-cli$redisArgs get "$loadavgKey" | cut -d'.' -f1 | grep '^[0-9][0-9]*$' || echo -n ''`
          rhdebug redis-cli$redisArgs get "$loadavgKey" "[$loadavg]"
          if [ -z "$loadavg" ]
          then
            rhwarn 'FAILED' redis-cli$redisArgs get "$loadavgKey"
            sleep 15 # sleep
          elif [ $loadavg -gt $loadavgLimit ]
          then
            rhwarn redis-cli$redisArgs get "$loadavgKey" "-- $loadavg"
            sleep 15 # sleep
            continue
          fi
          break
        done
      elif [ -n "$uptimeRemote" ]
      then
        while [ 1 ]
        do
          rhdebug "ssh $uptimeRemote uptime"
          local loadavg=`ssh "$uptimeRemote" uptime 2>&1 | tee $tmp.uptime |
             sed -n 's/.* load average: \([0-9]*\)\..*/\1/p' | grep '^[0-9][0-9]*$' || echo -n ''`
          if [ -z "$loadavg" ]
          then
            rhwarn "ssh $uptimeRemote uptime"
            cat $tmp.uptime
            sleep 15 # sleep
          elif [ $loadavg -gt $loadavgLimit ]
          then
            rhwarn redis-cli$redisArgs get "$loadavgKey" -- $loadavg
            sleep 15 # sleep
            continue
          fi
          rhdebug "ssh $uptimeRemote uptime -- loadavg $loadavg"
          break
        done
      fi
    fi
    while cat /proc/loadavg | grep -qv "^[0-${loadavgLimit}]\."
    do
      rhwarn loadavg `cat /proc/loadavg | cut -f1 -d' '`
      sleep 8 # sleep while load is too high
    done
  done
}

if [ $# -eq 0 ]
then
  RedisScan_help
else
  RedisScan_args "$@"
fi
