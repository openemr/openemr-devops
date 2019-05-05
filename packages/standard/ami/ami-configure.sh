#!/bin/bash -xe

exec > /var/log/openemr-configure.log 2>&1

cd /root/openemr-devops/packages/standard

# prepare the encrypted volume CFN just added
MKFSCOUNTER=0
until mkfs -t ext4 /dev/xvdd; do 
  if [ $MKFSCOUNTER == 6 ]; then
  echo 'mkfs on /dev/xvdd failure, aborting.'
  exit 1
  fi
  echo 'mkfs on /dev/xvdd failed, trying again in 5 seconds...'
  sleep 5
  let MKFSCOUNTER=MKFSCOUNTER+1
done
mkdir /mnt/docker
chown 711 /mnt/docker
cat snippets/fstab.append >> /etc/fstab
mount /mnt/docker

# move Docker infrastructure to encrypted volume (could I move less than this?)
service docker stop
mv /var/lib/docker/* /mnt/docker
rm -rf /var/lib/docker
ln -s /mnt/docker /var/lib/docker
service docker start

# pick up cloud settings
source /root/cloud-variables

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
  ./docker-compose create
  # load the Amazon CA
  cp snippets/rds-combined-ca-bundle.pem /mnt/docker/volumes/standard_sitevolume/_data/default/documents/certificates/mysql-ca
  # I'm not convinced this is stable
  chown 100 /mnt/docker/volumes/standard_sitevolume/_data/default/documents/certificates/mysql-ca
  # okay, now go
  ./docker-compose up -d
else
  # configure, but do not launch, OpenEMR docker
  ./docker-compose create
  # seed the target volumes with the stack backups
  ./scripts/restore.sh -r import
  # the old OpenEMR instance points to the old database, so repoint
  sed -i "s/^\\\$host\t=.*\;$/\$host\t= '$RECOVERY_NEWRDS'\;/" /mnt/docker/volumes/standard_sitevolume/_data/default/sqlconf.php
  # okay, now go
  ./docker-compose up -d
fi

# schedule Duplicity backups
ln -s /root/openemr-devops/packages/standard/scripts/backup.sh /etc/cron.daily/duplicity-backups
