
rhcalc() { # positive decimal arithmetic
  local expression="$1"
  local elseValue="$2"
  if which bc > /dev/null
  then
    if ! echo "scale=3; $expression" | bc | grep '^[\.0-9]*[0-9]$' 
    then
      echo "$elseValue"
      return 1
    fi
  elif which python > /dev/null
  then
    if ! python -c "print $expression"  | grep '^[\.0-9]*[0-9]$' 
    then
      echo "$elseValue"
      return 1
    fi
  else
    echo "$elseValue"
    return 1
  fi
}
