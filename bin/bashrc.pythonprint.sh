
_pythonprint() { 
  if [ $# -ne 1 ] 
  then
    >&2 echo "Invalid. Single argument only e.g. '$@'"
    return 1 
  fi
  python -c "import math; print $1"
}

alias pp=_pythonprint # e.g. "pp 2+2" should print 4

