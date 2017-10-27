#!/bin/bash

exec > /var/log/openemr-launch.log 2>&1

REPOBRANCH=master
#DOCKERLABEL=:5.0.0
DOCKERLABEL=@sha256:b07df8e81aee0f70d2e815b791b248010bd7d3244dab94120f1f5b3ab1c67fd6

while getopts "b:" opt; do
  case $opt in
    b)
      REPOBRANCH=$OPTARG
      ;;
    h)
      DOCKERLABEL=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --force-yes

apt-get install -y apt-transport-https ca-certificates git jq duplicity awscli python-boto
apt-key adv --keyserver hkp://ha.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
echo "deb https://apt.dockerproject.org/repo ubuntu-xenial main" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-engine
service docker start

docker pull openemr/openemr${DOCKERLABEL}

cd /root
if [[ $REPOBRANCH == master ]]; then
  git clone --single-branch https://github.com/openemr/openemr-devops.git && cd openemr-devops/stacks/AWS-mktplace
else
  git clone --single-branch --branch $REPOBRANCH https://github.com/openemr/openemr-devops.git && cd openemr-devops/stacks/AWS-mktplace
fi
curl -L https://github.com/docker/compose/releases/download/1.15.0/docker-compose-`uname -s`-`uname -m` > docker-compose
chmod +x docker-compose
