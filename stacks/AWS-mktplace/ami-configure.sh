#!/bin/bash

exec > /var/log/openemr-configure.log 2>&1

cd /root/openemr-devops/stacks/AWS-mktplace

mkfs -t ext4 /dev/xvdd
mkdir /mnt/docker
chown 711 /mnt/docker
cat fstab.append >> /etc/fstab
mount /mnt/docker

service docker stop
mv /var/lib/docker/* /mnt/docker
rm -rf /var/lib/docker
ln -s /mnt/docker /var/lib/docker
service docker start

cd /root/openemr-devops/stacks/AWS-mktplace
./docker-compose up --build -d
