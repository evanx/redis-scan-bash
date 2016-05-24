#!/bin/bash

set -u -e

minute=`date +%M`

rhabort() {
  >&2 echo "ABORT rhSetLoadAvgKey $*"
  return $1
}

rhSetLoadAvgKey() {
  [ $# -ge 1 ] || rhabort 'args'
  key=`echo "$1" | grep -e '^\w\S*$' || echo ''`
  [ -n "$key" ]
  shift && printf '%s' "$1" | grep -q '^-' || rhabort 3 "Arg should start with dash: $1"
  while [ `date +%M` -eq $minute ]
  do
    local loadavgInteger=`cat /proc/loadavg | cut -d'.' -f1 | grep [0-9]`
    redis-cli $@ setex $key 90 $loadavgInteger | grep -v ^OK
    sleep 13
  done
  [ $RH_LEVEL = 'debug' ] && >&2 echo "redis-cli $@ setex $key 90 $loadavgInteger"
}

rhSetLoadAvgKey 'cron:loadavg' -n 13
