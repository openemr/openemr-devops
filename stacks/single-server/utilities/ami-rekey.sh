#!/bin/bash
# chkconfig: 345 99 10
# description: on-boot check for contextual post-install changes

# Normally I would say installation as a service is wild overkill, but cron's
# @reboot isn't willing to make any guarantees about when exactly it runs what
# it runs.

case "$1" in
 start)
  ;;
 force)
  # this is a terrible idea
  rm -f /etc/appliance-unlocked
  ;;
 *)
  echo "not relevant"
  exit 1
  ;;
esac

if [ -f /etc/appliance-unlocked ]; then
  # only once
  exit 0
fi

# reset password
docker exec $(docker ps | grep openemr | cut -f 1 -d " ") /root/unlock_admin.sh $(curl http://169.254.169.254/latest/meta-data/instance-id)

# reset SSL
docker exec $(docker ps | grep openemr | cut -f 1 -d " ") rm -rf /etc/ssl/private/*
docker restart singleserver_openemr_1

# let's never speak of this again
touch /etc/appliance-unlocked
chkconfig --del ami-rekey
exit 0
