#!/bin/bash

exec > /tmp/lightsail-launch.log 2>&1

cd /root

apt-get update
apt-get install -y apt-transport-https ca-certificates git jq duplicity
apt-key adv --keyserver hkp://ha.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
echo "deb https://apt.dockerproject.org/repo ubuntu-xenial main" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-engine
service docker start

mkdir backups backups/mysql backups/www

git clone https://github.com/openemr/openemr-devops.git --branch wip-xtrabackup && cd openemr-devops/docker
curl -L https://github.com/docker/compose/releases/download/1.15.0/docker-compose-`uname -s`-`uname -m` > docker-compose
chmod +x docker-compose
./docker-compose up -d --build

cd lightsail
chmod a+x duplicity-setup.sh
./duplicity-setup.sh

echo "launch.sh: done"
