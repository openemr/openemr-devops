#!/bin/bash

### BEGIN INIT INFO
# Provides:          vm-rekey
# Required-Start:    docker
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: on-boot check for contextual post-install changes
# Description:       multiline_description
### END INIT INFO

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

# we need to wait a little while longer for MySQL to crank
sleep 15

# reset password
docker exec $(docker ps | grep _openemr | cut -f 1 -d " ") /root/unlock_admin.sh $(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/openemr_admin_password)

# reset SSL
docker exec $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh -c 'rm -rf /etc/ssl/private/*'
docker restart lightsail_openemr_1

# let's never speak of this again
touch /etc/appliance-unlocked
update-rc.d -f vm-rekey remove
exit 0
