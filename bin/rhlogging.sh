
rhinit() {
  if [ -z "${BASH-}" ] 
  then
    >&2 echo 'Please use bash shell!'
    if [ $0 = 'bash' ] 
    then
      return 3
    else
      exit 3
    fi
  fi
  RH_WIDTH=`tput cols`
}

rhinit

rhnone() {
  return 0
}

rhcomment() {
  if [ -t 1 ]
  then
    >&2 echo -e "\e[90m${*}\e[39m"
  else
    >&2 echo "DEBUG ${*}"
  fi
}

rhnote() {
  rhcomment "$*"
}

rhdebug() {
  if [ "${RHLEVEL-}" = 'debug' ]
  then
    rhcomment "$@"
  fi
}

rhhead() {
  if [ -t 1 ]
  then
    >&2 echo -e "\n\e[1m\e[36m${*}\e[39m\e[0m"
  else
    >&2 echo "\n# ${*}"
  fi
}

rhinfo() {
  if [ -t 1 ]
  then
    >&2 echo -e "\e[1m\e[94m${*}\e[39m\e[0m"
  else
    >&2 echo "INFO ${*}"
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

rhalert() {
  if [ -t 1 ]
  then
    >&2 echo -e "\e[1m\e[33m${*}\e[39m\e[0m"
  else
    >&2 echo "WARNING ${*}"
  fi
}

rhwarn() {
  rhalert "$*"
}

rherror() {
   if [ -t 1 ]
   then
     >&2 echo -e "\e[1m\e[91m${*}\e[39m\e[0m"
   else
     >&2 echo "ERROR ${*}"
   fi
}

rhsection() {
  echo
  rhwarn `printf '%200s\n' | cut -b1-${RH_WIDTH} | tr ' ' -`
  rhwarn "$*"
}

rhsub() {
  echo
  rhnote `printf '%200s\n' | cut -b1-${RH_WIDTH} | tr ' ' \.`
  rhinfo "$*"
}

declare -A ErrorCodes=( 
  [GENERAL]=1 [ENV]=3 [PARAM]=4 [APP]=5 
)

# command: rhabort $code $*
# example: rhabort 1 @$LINENO "error message" $some
# specify 1 (default) to limit 254. 
# Ideally use 3..63 for custom codes
# We use 3 for ENV errors (a catchall for system/dep/env), 4 for subsequent APP errors
# returns nonzero code e.g. for scripts with set -e 
rhabort() {
  local code=1
  if [ $# -gt 0 ]
  then
    if echo "$1" | grep -q '^[A-Z]\S*$'
    then
      local errorCode="${ErrorCodes[$1]}"
      rhdebug errorCode $1 $errorCode 
      if [ "$errorCode" -gt 0 ]
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
  for key in "${!ErrorCodes[@]}"
  do
    local value=${ErrorCodes[$key]}
    if [ $value -eq $code ]
    then
      errorName="$key"
      break
    fi
  done
  if [ $# -gt 0 ]
  then
    if echo "$1" | grep -q 'Try: '
    then
      rhinfo 'Try: '
      rhinfo "`echo "$1" | cut -b6-199`" 
      shift
    fi
  fi
  rherror "Aborting. Reason: ${*} (code $code $errorName)"
  if [ $code -le 0 ]
  then
    code=1
  elif [ $code -ge 255 ]
  then
    code=254
  fi
  return $code
}
