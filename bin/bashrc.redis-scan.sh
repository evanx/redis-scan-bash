
RedisScan_clean() {
  rm -f ~/tmp/redis-scan/${$}*
  local findCount=`find ~/tmp/redis-scan -mtime +1 -type f | wc -l`
  [ $findCount -gt 0 ] && rhwarn "found $findCount old files in ~/tmp/redis-scan"
  find ~/tmp/redis-scan -mtime +1 -type f -delete
}

RedisScan() { # scan command with sleep between iterations
  local eachLimit=${eachLimit:-1000} # limit of keys to scan, pass 0 to disable
  local scanSleep=${scanSleep:-.250} # sleep 250ms between each scan
  local eachCommandSleep=${eachCommandSleep:-.025} # sleep 25ms between each command
  local loadavgLimit=${loadavgLimit:-1} # sleep while loadavg above this threshold
  local loadavgKey=${loadavgKey:-''} # ascertain loadavg from Redis key
  local uptimeRemote=${uptimeRemote:-''} # ascertain loadavg via ssh
  rhdebug "redis-scan args: ${*}"
  mkdir -p ~/tmp/redis-scan
  local tmp=~/tmp/redis-scan/$$
  rhdebug "tmp $tmp"
  which bc > /dev/null || rhwarn 'Please install: bc'
  local keyScanCommands='sscan zscan hscan'
  local scanCommands='scan sscan zscan hscan'
  local matchTypes='string set zset list hash any' # 'any' for testing
  local eachCommands='type ttl persist expire del echo' # 'echo' for testing
  local safeEachCommands='type ttl get scard smembers zcard llen hlen hgetall hkeys sscan zscan lrange'
  local eachArgsCommands='expire lrange sscan hscan zrevrange zrange'
  local -A typeEachCommands
  typeEachCommands['string']='get'
  typeEachCommands['list']='llen lrange'
  typeEachCommands['hash']='hlen hgetall hkeys hscan'
  typeEachCommands['set']='scard smembers sscan'
  typeEachCommands['zset']='zcard zrevrange zrange zscan'
  for keyType in string list hash set zset
  do
    eachCommands="$eachCommands ${typeEachCommands[$keyType]}"
  done
  rhdebug "eachCommands $eachCommands"
  local commit=${commit:=0}
  local cursor=${cursor:=0}
  local redisArgs=''
  local matchType=''
  local eachCommand=''
  local eachArgs=''
  local scanCommand='scan'
  local scanKey=''
  local -a scanArgs=()
  rhdebug "sleep: $scanSleep, loadavgLimit: $loadavgLimit, eachLimit: $eachLimit, args:" "$@"
  # check initial arg for dbn
  if [ $# -eq 0 ]
  then
    scanCommand='scan'
  else
    if echo "$1" | grep -q "^[0-9][0-5]\{0,1\}$"
    then
      rherror 'Use @dbn for the db number'
      local dbn="$1"
      shift
      redisArgs=" -n $dbn"
      rhinfo "dbn $dbn"
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
    if printf '%s' "$arg" | grep -q '^@'
    then
      local argt=`echo "$arg" | tail -c+2`
      if [ $argt = 'commit' ]
      then
        commit=1
      elif [ $argt = 'nolimit' ]
      then
        eachLimit=0
      else
        matchType="$argt"
        if echo "$matchTypes" | grep -qv "$matchType"
        then
          rherror "Invalid specified key type: $matchType. Expecting one of: $matchTypes"
          RedisScan_clean
          return $LINENO
        fi
        rhdebug "matchType $matchType"
      fi
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
        rherror "Missing key for $scanCommand"
        RedisScan_clean
        return $LINENO
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
    elif [ "$arg" = '--' ]
    then
      eachCommand="$1"
      if ! shift
      then
        rherror "missing each command [$@]"
        RedisScan_clean
        return $LINENO
      fi
      rhdebug "each $eachCommand [$@]"
      break
    elif printf '%s' "$arg" | grep -qi '^match$'
    then
      if [ $# -eq 0 ]
      then
        rherror "missing match pattern"
        RedisScan_clean
        return $LINENO
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
    else
      redisArgs="$redisArgs $arg"
    fi
  done
  rhdebug "redisArgs [$redisArgs]"
  # check scanCommand
  if [ ${#scanCommand} -eq 0 ]
  then
    rherror "Missing scan command: $scanCommands"
    RedisScan_clean
    return $LINENO
  fi
  if echo "$scanCommand" | grep -qvi "scan"
  then
    rherror "Invalid scan command: $scanCommand. Expecting one of: $scanCommands"
    RedisScan_clean
    return $LINENO
  fi
  # handle scan args
  if [ ${#eachCommand} -eq 0 ]
  then
    # iterate scanArgs until '--'
    while [ $# -gt 0 ]
    do
      local arg="$1"
      shift
      if printf '%s' "$arg" | grep -q '^@'
      then
        local argt=`echo "$arg" | tail -c+2`
        if [ $argt = 'commit' ]
        then
          commit=1
        elif [ $argt = 'nolimit' ]
        then
          eachLimit=0
        else
          matchType="$argt"
          if echo "$matchTypes" | grep -qv "$matchType"
          then
            rherror "Invalid specified key type: $matchType. Expecting one of: $matchTypes"
            RedisScan_clean
            return $LINENO
          fi
          rhdebug "matchType $matchType"
        fi
      elif [ "$arg" = '--' ]
      then
        if [ $# -eq 0 ]
        then
          rherror "Missing 'each' command after '--' delimiter"
          RedisScan_clean
          return $LINENO
        fi
        eachCommand="$1"
        shift
        rhdebug eachCommand $eachCommand
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
  if [ ${#scanArgs[@]} -eq 0 ]
  then
    rhdebug scanArgs empty
  else
    rhdebug scanArgs "${scanArgs[@]}"
  fi
  # check eachCommand
  rhdebug eachCommand $eachCommand
  if [ ${#eachCommand} -gt 0 ]
  then
    if echo " $eachCommands " | grep -qv " $eachCommand "
    then
      rherror "Invalid each command: $eachCommand. Try one of: $eachCommands"
      RedisScan_clean
      return $LINENO
    fi
    if echo " $eachArgsCommands " | grep -q " $eachCommand "
    then
      if [ $# -eq 0 ]
      then
        rherror "Command (each) missing args: $eachCommand"
        RedisScan_clean
        return $LINENO
      fi
    fi
    if [ ${#matchType} -eq 0 ]
    then
      for keyType in set zset list hash
      do
        rhdebug "eachCommand: $eachCommand, $keyType: ${typeEachCommands[$keyType]}"
        if echo " ${typeEachCommands[$keyType]} " | grep -q " $eachCommand "
        then
          matchType=$keyType
          break
        fi
      done
    fi
    while [ $# -gt 0 ]
    do
      local arg="$1"
      shift
      if [[ "$arg" =~ ^@ ]]
      then
        local argt=`echo "$arg" | tail -c+2`
        if [ $argt = 'commit' ]
        then
          commit=1
        elif [ $argt = 'nolimit' ]
        then
          eachLimit=0
        else
          matchType="$argt"
          if echo "$matchTypes" | grep -qv "$matchType"
          then
            rherror "Invalid specified key type: $matchType. Expecting one of: $matchTypes"
            RedisScan_clean
            return $LINENO
          fi
          rhdebug "matchType $matchType"
        fi
      elif printf '%s' "$arg" | grep -q '^-'
      then
        rherror "Unsupported each arg: $arg"
        RedisScan_clean
        return $LINENO
      elif printf '%s' "$arg" | grep -q '^@'
      then
        local argt=`echo "$arg" | tail -c+2`
        if [ $argt = 'commit' ]
        then
          commit=1
        elif [ $argt = 'nolimit' ]
        then
          eachLimit=0
        else
          matchType="$argt"
          if echo "$matchTypes" | grep -qv "$matchType"
          then
            rherror "Invalid specified key type: $matchType. Expecting one of: $matchTypes"
            RedisScan_clean
            return $LINENO
          fi
          rhdebug "matchType $matchType"
        fi
      else
        eachArgs="$eachArgs $arg"
      fi
    done
    if [ ${#scanArgs[@]} -eq 0 ]
    then
      rhwarn "scan: redis-cli$redisArgs $scanCommand$scanKey $cursor"
    else
      rhwarn "scan: redis-cli$redisArgs $scanCommand$scanKey $cursor ${scanArgs[@]}"
    fi
    if [ ${#matchType} -gt 0 ]
    then
      rhinfo "type: @$matchType, eachLimit: $eachLimit, commit: $commit, sleep: $scanSleep, loadavgMax: $loadavgMax"
    else
      rhinfo "eachLimit: $eachLimit, commit: $commit, sleep: $scanSleep, loadavgMax: $loadavgMax"
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
  fi
  # scan keys
  local keyCount=0
  local cursorCount=0
  local stime=`date +%s`
  local slowlogLen=`redis-cli$redisArgs slowlog len`
  if ! [[ "$slowlogLen" =~ ^[0-9][0-9]*$ ]]
  then
     rherror "redis-cli$redisArgs slowlog len"
     RedisScan_clean
     return $LINENO
  fi
  rhdebug "redis-cli$redisArgs slowlog len # $slowlogLen"
  while [ true ]
  do
    sleep .005 # hard-coded minimum scan sleep, also $scanSleep below
    if [ $eachLimit -gt 0 -a $keyCount -gt $eachLimit ]
    then
      rherror "Limit reached: eachLimit $eachLimit"
      RedisScan_clean
      return 1 # special exit code
    fi
    local scanArgsString=''
    if [ ${#scanArgs[@]} -eq 0 ]
    then
      redis-cli$redisArgs $scanCommand$scanKey $cursor > $tmp
      if [ $? -ne 0 ] || head -1 $tmp | grep -qv '^[0-9][0-9]*$'
      then
        rherror redis-cli$redisArgs $scanCommand$scanKey $cursor
        RedisScan_clean
        return $LINENO
      fi
    else
      scanArgsString="${scanArgs[@]}"
      redis-cli$redisArgs $scanCommand$scanKey $cursor "${scanArgs[@]}" > $tmp
      if [ $? -ne 0 ] || head -1 $tmp | grep -qv '^[0-9][0-9]*$'
      then
        rherror redis-cli$redisArgs $scanCommand$scanKey $cursor $scanArgsString
        RedisScan_clean
        return $LINENO
      fi
    fi
    cursor=`head -1 $tmp`
    keyCount=$[ $keyCount + `cat $tmp | wc -l` - 1 ]
    if [ $cursorCount -eq 0 -o $[ $cursorCount % 10 ] -eq 0 ]
    then
      rhdebug "redis-cli$redisArgs $scanCommand $cursor $scanArgsString # cursor $cursor, keys $keyCount, @$matchType each [$eachCommand]"
    fi
    cursorCount=$[ $cursorCount + 1 ]
    if [ ${#matchType} -eq 0 -a ${#eachCommand} -eq 0 ]
    then
      if [ `tail -n +2 $tmp | sed '/^$/d' | wc -l` -gt 0 ]
      then
        tail -n +2 $tmp
      fi
    else
      for key in `tail -n +2 $tmp`
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
          rhinfo redis-cli$redisArgs $eachCommand $key$eachArgs
          if [ $commit -eq 1 ] || echo " $safeEachCommands " | grep -q " $eachCommand "
          then
            sleep $eachCommandSleep
            redis-cli$redisArgs $eachCommand $key$eachArgs > $tmp.each
            if [ $? -ne 0 ] || head -1 $tmp.each | grep -q '^(error)\|^WRONGTYPE\|^Unrecognized option\|^Could not connect'
            then
              cat $tmp.each
              RedisScan_clean
              return $LINENO
            fi
            cat $tmp.each
          fi
        fi
      done
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
      rherror "redis-cli$redisArgs slowlog len"
      RedisScan_clean
      return $LINENO
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
  RedisScan_clean
}

alias redis-scan=RedisScan
