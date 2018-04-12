#!/bin/bash

# OpenEMR Lightsail single-server launcher
# usage: launch.sh -t openemr:dev -s 2 -b wip-feature -d 5.0.0
#        -t: specific OpenEMR container to load
#        -s: amount of swap to allocate, in gigabytes
#        -b: oe-devops repo branch to load instead of master
#        -d: specify repository build file to start in developer mode (local containers, open ports)

exec > /tmp/launch.log 2>&1

SWAPAMT=1
SWAPPATHNAME=/mnt/auto.swap

CURRENTDOCKER=openemr:latest
OVERRIDEDOCKER=$CURRENTDOCKER

DEVELOPERMODE=0
REPOBRANCH=master
CURRENTBUILD=5.0.1
OVERRIDEBUILD=$CURRENTBUILD

while getopts "s:b:t:d:" opt; do
  case $opt in
    s)
      SWAPAMT=$OPTARG
      ;;
    b)
      REPOBRANCH=$OPTARG
      ;;
    d)
      OVERRIDEBUILD=$OPTARG
      DEVELOPERMODE=1
      ;;
    t)
      OVERRIDEDOCKER=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$opt" >&2
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
  git clone --single-branch https://github.com/openemr/openemr-devops.git && cd openemr-devops/packages/lightsail
else
  git clone --single-branch --branch $REPOBRANCH https://github.com/openemr/openemr-devops.git && cd openemr-devops/packages/lightsail
fi
curl -L https://github.com/docker/compose/releases/download/1.15.0/docker-compose-`uname -s`-`uname -m` > docker-compose
chmod +x docker-compose

if [[ $DEVELOPERMODE == 0 ]]; then
  ln -s docker-compose.prod.yml docker-compose.yml
  if [[ $CURRENTDOCKER != $OVERRIDEDOCKER ]]; then
    echo launch.sh: switching to docker image $OVERRIDEDOCKER, from $CURRENTDOCKER
    sed -i "s^openemr/$CURRENTDOCKER^openemr/$OVERRIDEDOCKER^" docker-compose.yml
  fi
else
  ln -s docker-compose.dev.yml docker-compose.yml
  if [[ $CURRENTBUILD != $OVERRIDEBUILD ]]; then
    echo launch.sh: switching to developer build $OVERRIDEBUILD, from $CURRENTBUILD
    sed -i "s^../../docker/openemr/$CURRENTBUILD^../../docker/openemr/$OVERRIDEBUILD^" docker-compose.yml
  fi
fi
./docker-compose up -d --build

chmod a+x duplicity/*.sh

cp duplicity/backup.sh /etc/cron.daily/duplicity-backups
cp duplicity/restore.sh /root/restore.sh

echo "launch.sh: done"
