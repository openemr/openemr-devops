#!/bin/bash

### BEGIN INIT INFO
# Provides:          ami-rekey
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

# wait a while for services to start  
until docker container ls | grep openemr/openemr >& /dev/null
do      
    sleep 5
done

until docker top $(docker ps | grep _openemr | cut -f 1 -d " ") | grep httpd &> /dev/null
do
    sleep 3
done

# reset password
docker exec $(docker ps | grep _openemr | cut -f 1 -d " ") /root/unlock_admin.sh $(curl http://169.254.169.254/latest/meta-data/instance-id)

# reset SSL
docker exec $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh -c 'rm -f /etc/ssl/private/* /etc/ssl/docker-selfsigned-configured'
docker restart lightsail_openemr_1

# let's never speak of this again
touch /etc/appliance-unlocked
update-rc.d -f ami-rekey remove
exit 0
