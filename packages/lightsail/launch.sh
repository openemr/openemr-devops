#!/bin/bash

# OpenEMR Lightsail single-server launcher
# usage: launch.sh -t openemr:dev -s 2 -b wip-feature -d 5.0.2
#        -t: specific OpenEMR container to load
#        -s: amount of swap to allocate, in gigabytes
#        -b: oe-devops repo branch to load instead of master
#        -d: specify x86 repository build file to start in developer mode (local containers, open ports)
#        -e: empty shell mode (do not attempt autoconfiguration)

exec > /var/log/lightsail-launch.log 2>&1

SWAPAMT=1
SWAPPATHNAME=/mnt/auto.swap

CURRENTDOCKER=openemr:7.0.2
OVERRIDEDOCKER=$CURRENTDOCKER

DEVELOPERMODE=0
EMPTYSHELLMODE=0
REPOBRANCH=master
CURRENTBUILD=7.0.2
OVERRIDEBUILD=$CURRENTBUILD

while getopts "es:b:t:d:" opt; do
  case $opt in
    e)
      EMPTYSHELLMODE=1
      ;;
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

f () {
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
  
  # Make sure we don't fail out if there is an interactive prompt... go with defaults
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get dist-upgrade -y
  apt autoremove -y
  apt-get install jq git duplicity containerd docker-compose-v2 python3-boto3 -y

  mkdir backups

  if [[ $REPOBRANCH == master ]]; then
    git clone --single-branch https://github.com/openemr/openemr-devops.git && cd openemr-devops/packages/lightsail
  else
    git clone --single-branch --branch $REPOBRANCH https://github.com/openemr/openemr-devops.git && cd openemr-devops/packages/lightsail
  fi

  if [[ $EMPTYSHELLMODE == 1 ]]; then
    ln -s docker-compose.shell.yml docker-compose.yml
    if [[ $CURRENTDOCKER != $OVERRIDEDOCKER ]]; then
      echo launch.sh: switching to docker image $OVERRIDEDOCKER, from $CURRENTDOCKER
      sed -i "s^openemr/$CURRENTDOCKER^openemr/$OVERRIDEDOCKER^" docker-compose.yml
    fi
  elif [[ $(dpkg --print-architecture) =~ arm && $DEVELOPERMODE == 0 ]]; then
    ln -s docker-compose.arm.yml docker-compose.yml
    if [[ $CURRENTDOCKER != $OVERRIDEDOCKER ]]; then
      echo launch.sh: switching to docker image $OVERRIDEDOCKER, from $CURRENTDOCKER
      sed -i "s^openemr/$CURRENTDOCKER^openemr/$OVERRIDEDOCKER^" docker-compose.yml
    fi      
  elif [[ $(dpkg --print-architecture) =~ arm ]]; then
    ln -s docker-compose.arm.dev.yml docker-compose.yml
    if [[ $CURRENTDOCKER != $OVERRIDEDOCKER ]]; then
      echo launch.sh: switching to docker image $OVERRIDEDOCKER, from $CURRENTDOCKER
      sed -i "s^openemr/$CURRENTDOCKER^openemr/$OVERRIDEDOCKER^" docker-compose.yml
    fi    
  elif [[ $DEVELOPERMODE == 0 ]]; then
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
  docker compose up -d --build

  chmod a+x duplicity/*.sh  
  cp duplicity/restore.sh duplicity/wait_until_ready.sh /root

  echo launch.sh: waiting for init...
  duplicity/wait_until_ready.sh
  
  cp duplicity/backup.sh /etc/cron.daily/duplicity-backups

  echo "launch.sh: done"
  exit 0
}

f
echo failure?
exit 1
