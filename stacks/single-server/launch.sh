#!/bin/bash

# OpenEMR Cloud Express launcher
# usage: launch.sh -s 2 -b wip-feature -d
#        -s: amount of swap to allocate, in gigabytes
#        -b: repo branch to load instead of master
#        -d: start in developer mode, force local dockers and open ports

exec > /tmp/launch.log 2>&1

SWAPAMT=1
SWAPPATHNAME=/mnt/auto.swap
REPOBRANCH=master
DEVELOPERMODE=0

while getopts "s:b:d" opt; do
  case $opt in
    s)
      SWAPAMT=$OPTARG
      ;;
    b)
      REPOBRANCH=$OPTARG
      ;;
    d)
      DEVELOPERMODE=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

cd /root

# bad news for EC2, *necessary* for Lightsail nano
if [[ $SWAPAMT != 0 ]]; then
  echo Allocating ${SWAPAMT}G swap...
  fallocate -l ${SWAPAMT}G $SWAPPATHNAME
  mkswap $SWAPPATHNAME
  chmod 600 $SWAPPATHNAME
  swapon $SWAPPATHNAME
  echo "$SWAPPATHNAME  none  swap  sw 0  0" >> /etc/fstab
else
  echo Skipping swap allocation...
fi

apt-get update
apt-get install -y apt-transport-https ca-certificates git jq duplicity
apt-key adv --keyserver hkp://ha.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
echo "deb https://apt.dockerproject.org/repo ubuntu-xenial main" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-engine
service docker start

mkdir backups

if [[ $REPOBRANCH == master ]]; then
  git clone --single-branch https://github.com/openemr/openemr-devops.git && cd openemr-devops/stacks/single-server
else
  git clone --single-branch --branch $REPOBRANCH https://github.com/openemr/openemr-devops.git && cd openemr-devops/stacks/single-server
fi
curl -L https://github.com/docker/compose/releases/download/1.15.0/docker-compose-`uname -s`-`uname -m` > docker-compose
chmod +x docker-compose

# I'm pretty sure I'm doing this wrong
if [[ $DEVELOPERMODE == 0 ]]; then
  ln -s docker-compose.prod.yml docker-compose.yml
else
  ln -s docker-compose.dev.yml docker-compose.yml
fi
./docker-compose up -d --build

chmod a+x *.sh utilities/*.sh duplicity/*.sh

cp duplicity/backup.sh /etc/cron.daily/duplicity-backups
chmod a+x /etc/cron.daily/duplicity-backups
cp duplicity/restore.sh /root/restore.sh

echo "launch.sh: done"
