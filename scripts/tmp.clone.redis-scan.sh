
set -u -e

[ -n $BASH ]

[ $commit -eq 1 ] && rm -rf ~/tmp/redis-scan-bash

[ ! -d ~/tmp/redis-scan-bash ]

( set -e
  mkdir -p ~/tmp
  cd ~/tmp
  git clone https://github.com/evanx/redis-scan-bash
  cd rquery
  ls -l bin
)

cd ~/tmp/redis-scan-bash

source bin/bashrc.rhlogging.sh
source bin/bashrc.redis-scan.sh

redis-scan
redis-scan @set
redis-scan @hash match '*'
redis-scan @set -- ttl
