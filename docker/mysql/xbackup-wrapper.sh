#!/bin/bash

exec > /tmp/xtrabackup-launch.log 2>&1

cd /root

if [ ! -f allsetup.ok ]; then
  ./xbackup.sh -a && ./xbackup.sh -t full && touch allsetup.ok && exit 0
  exit 1
fi

if [ $(date +%u) == 7 ]; then
  ./xbackup.sh -t full -f
else
  ./xbackup.sh -t incr
fi;

exit $?
