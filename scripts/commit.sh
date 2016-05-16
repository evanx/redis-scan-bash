
set -u -e

c1commit() {
  message="$1"
  git add -A
  git commit -m "$message" 
  git push
  echo; echo "done"
  git status
}

if [ $# -eq 1 ]
then
  c1commit "$1"
else
  echo "usage: message"
fi 

