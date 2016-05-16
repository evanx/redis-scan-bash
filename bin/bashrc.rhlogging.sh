
rhnone() {
  return 0
}

rhdebug() {
  if [ -t 1 -a "$RHLEVEL" = 'debug' ]
  then
    >&2 echo -e "\e[90m${*}\e[39m"
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

rhwarn() {
   if [ -t 1 ]
   then
     >&2 echo -e "\e[1m\e[33m${*}\e[39m\e[0m"
   else
     >&2 echo "WARNING ${*}"
   fi
}

rherror() {
   if [ -t 1 ]
   then
     >&2 echo -e "\e[1m\e[91m${*}\e[39m\e[0m"
   else
     >&2 echo "ERROR ${*}"
   fi
}
