#!/bin/bash

exec > /tmp/xtrabackup-launch.log 2>&1

cd /root

if [ ! -f allsetup.ok ]; then
  ./xbackup.sh -u openemr -a && ./xbackup.sh -t full && touch allsetup.ok && exit 0
  exit 1
fi

if [ -f force-full-backup ]; then
  rm force-full-backup
  ./xbackup.sh -t full
  exit $?
fi

# I don't like forcing it like this, but if the backup fails one day, we need to try it the next
# here's the problem: manual run during an automated run will cause destruction and havoc and woe
if [ $(date +%u) == 7 ]; then
  ./xbackup.sh -t full -f
else
  ./xbackup.sh -t incr -f
fi;

exit $?
