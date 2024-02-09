#!/bin/bash -xe

exec > /var/log/openemr-configure.log 2>&1

cd /root/openemr-devops/packages/standard

# pick up cloud settings
source /root/cloud-variables

# prepare the encrypted volume CFN just added
# this used to be in a weird ready-loop but that doesn't make any sense to me
DVOL_SERIAL=`echo $DVOL | sed s/-//`
DVOL_DEVICE=/dev/`lsblk -no +SERIAL | grep $DVOL_SERIAL | awk '{print $1}'`
mkfs -t ext4 $DVOL_DEVICE
echo $DVOL_DEVICE /mnt/docker ext4 defaults,nofail 0 0 >> /etc/fstab
mkdir /mnt/docker
# TODO: wait, chown? what is user 711? is that supposed to be chmod?
chown 711 /mnt/docker
mount /mnt/docker

# move Docker infrastructure to encrypted volume (could I move less than this?)
service docker stop
mv /var/lib/docker/* /mnt/docker
rm -rf /var/lib/docker
ln -s /mnt/docker /var/lib/docker
service docker start

# configure Duplicity backup and restore
touch /tmp/mypass
chmod 500 /tmp/mypass
openssl rand -base64 32 >> /tmp/mypass
aws s3 cp /tmp/mypass s3://$S3/Backup/passphrase.txt --sse aws:kms --sse-kms-key-id $KMS
rm /tmp/mypass
ln -s /root/openemr-devops/packages/standard/scripts/restore.sh /root/restore.sh

cd /root/openemr-devops/packages/standard
if [ -z "$RECOVERYS3" ]; then
  # configure, but do not launch, OpenEMR docker
  docker-compose create
  # now we'll install the AWS certs we got when I built the instance
  # this doesn't feel like the right way to do it but it works  
  mv /root/mysql-ca /mnt/docker/volumes/standard_sitevolume/_data/default/documents/certificates
  chown 1000 /mnt/docker/volumes/standard_sitevolume/_data/default/documents/certificates/mysql-ca
  # okay, now go
  docker-compose up -d
else
  # configure, but do not launch, OpenEMR docker
  docker-compose create
  # seed the target volumes with the stack backups
  ./scripts/restore.sh -r import
  # the old OpenEMR instance points to the old database, so repoint
  sed -i "s/^\\\$host\t=.*\;$/\$host\t= '$RECOVERY_NEWRDS'\;/" /mnt/docker/volumes/standard_sitevolume/_data/default/sqlconf.php
  # okay, now go
  docker-compose up -d
fi

# schedule Duplicity backups
ln -s /root/openemr-devops/packages/standard/scripts/backup.sh /etc/cron.daily/duplicity-backups
