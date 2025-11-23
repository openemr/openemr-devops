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

if [[ -f /etc/appliance-unlocked ]]; then
  # only once
  exit 0
fi

# wait a while for services to start
# shellcheck disable=SC2312
until docker container ls | grep openemr -q
do
    sleep 5
done
CONTAINER="$(docker compose -p appliance ps --services openemr -qa)"

# shellcheck disable=SC2312
until [[ "$(docker container inspect "${CONTAINER}" | jq '.[].State.Health.Status' -r)" == "healthy" ]]
  do
      sleep 5
  done

# reset password
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCEID=$(curl -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)
docker compose -p appliance exec openemr /root/unlock_admin.sh "${INSTANCEID}"

# reset SSL
docker compose -p appliance exec openemr /bin/sh -c 'rm -f /etc/ssl/private/* /etc/ssl/docker-selfsigned-configured'
docker compose -p appliance restart openemr

# let's never speak of this again
touch /etc/appliance-unlocked
update-rc.d -f ami-rekey remove
exit 0
