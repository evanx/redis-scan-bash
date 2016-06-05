
rhinit() {
  if [ -z "${BASH-}" ] 
  then
    >&2 echo 'Please use bash shell!'
    exit 3
  fi
  RH_WIDTH=`tput cols`
}

rhinit

rhnone() {
  return 0
}

rhnote() {
  if [ -t 1 ]
  then
    >&2 echo -e "\e[90m${@}\e[39m"
  else
    >&2 echo "DEBUG ${@}"
  fi
}

rhdebug() {
  if [ "${RHLEVEL-}" = 'debug' ]
  then
    rhnote "$@"
  fi
}

rhhead() {
  if [ -t 1 ]
  then
    >&2 echo -e "\e[1m\e[36m${@}\e[39m\e[0m"
  else
    >&2 echo "INFO ${@}"
  fi
}

rhinfo() {
  if [ -t 1 ]
  then
    >&2 echo -e "\e[1m\e[94m${@}\e[39m\e[0m"
  else
    >&2 echo "INFO ${@}"
  fi
}

rhprop() {
   if [ -t 1 ]
   then
     >&2 echo -e "\e[1m\e[36m${1}\e[0m \e[39m${2}\e[39m\e[0m"
   else
     >&2 echo "$1 $2"
   fi
}

rhwarn() {
   if [ -t 1 ]
   then
     >&2 echo -e "\e[1m\e[33m${@}\e[39m\e[0m"
   else
     >&2 echo "WARNING ${@}"
   fi
}

rherror() {
   if [ -t 1 ]
   then
     >&2 echo -e "\e[1m\e[91m${@}\e[39m\e[0m"
   else
     >&2 echo "ERROR ${@}"
   fi
}

rhsection() {
  echo
  rhwarn `printf '%200s\n' | cut -b1-${RH_WIDTH} | tr ' ' -`
  rhwarn "$@"
}

rhsub() {
  echo
  rhnote `printf '%200s\n' | cut -b1-${RH_WIDTH} | tr ' ' \.`
  rhinfo "$@"
}

RHCODES="GENERAL=1 BUILTIN=2 ENV=3 PARAM=5 APP=6 OPTION=63"

rhKey() {
  local value="$1"
  shift
  local elseValue="$1"
  for entry in "$@"
  do
    local k=`echo "$entry" | cut -d'=' -f1`
    local v=`echo "$entry" | cut -d'=' -f2`
    if [ "${v}" = "${value}" ] 
    then
      echo "$k"
      return
    fi
  done
  echo "$elseValue"
}

rhGet() {
  local key="$1"
  shift
  local elseValue="$1"
  shift
  for entry in "$@"
  do
    local k=`echo "$entry" | cut -d'=' -f1`
    local v=`echo "$entry" | cut -d'=' -f2`
    if [ "${k}" = "${key}" ]
    then
      echo "$v"
      return
    fi
  done
  echo "$elseValue"
}

# command: rhabort $code $*
# example: rhabort 1 @$LINENO "error message" $some
# specify 1 (default) to limit 254. 
# Ideally use 3..63 for custom codes
# We use 3 for ENV errors (a catchall for system/dep/env), 4 for subsequent APP errors
# returns nonzero code e.g. for scripts with set -e 
rhabort() {
  local code=1
  local lineno=0
  if [ $# -gt 0 ]
  then
    if echo "$1" | grep -q '^[A-Z]\S*$'
    then
      local errorCode=`rhGet $1 '' $RHCODES`
      rhdebug "errorCode $1 $errorCode"
      if [ -n "$errorCode" ]
      then
        code=$errorCode
        shift
      fi
    elif echo "$1" | grep -q '^[0-9][0-9]*$'
    then
      code=$1
      shift
    fi
  fi
  if [ $# -gt 0 ]
  then
    if echo "$1" | grep -q '^[0-9][0-9]*$'
    then
      lineno=$1
      shift
    fi
  fi
  if [ $# -gt 0 ]
  then
    if echo "$1" | grep -q 'Try: '
    then
      rhinfo 'Try: '
      rhinfo "`echo "$1" | cut -b6-199`" 
      shift
    fi
  fi
  local errorName=`rhKey $code $code $RHCODES`
  rherror "Aborting. Reason: ${*} (line $lineno, code $errorName)"
  if [ $code -le 0 ]
  then
    code=1
  elif [ $code -ge 255 ]
  then
    code=254
  fi
  return $code
}
