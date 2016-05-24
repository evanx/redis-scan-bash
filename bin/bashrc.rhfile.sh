
# rhFileModAgo <file> 
# returns 3 if file does not exist, otherwise 0
# echos empty line if the file does not exist
# echos the time elapsed since the last modtime until now (the system clock)
# echos at least 1 i.e. if the modtime is the current second, still returns 1
rhFileModAgo() {
  local file="$1"
  if [ ! -r "$file" ]
  then
    echo ''
    return 3
  else
    local modtime=`stat -c %Y $file`
    local now=`date +%s`
    if [ $now -lt $modtime ]
    then
      >&2 echo "ERROR rhFileModAgo $modtime is in the future for file: $file"
      return 4
    elif [ $now -eq $modtime ]
    then
      echo 1
    else
      echo $[ $now - $modtime ]
    fi
    return 0
  fi
}

