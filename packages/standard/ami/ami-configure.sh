#!/bin/bash -xe

exec > /var/log/openemr-configure.log 2>&1

cd /root/openemr-devops/packages/standard

# prepare the encrypted volume CFN just added
mkfs -t ext4 /dev/xvdd
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

# configure Duplicity backups
touch /tmp/mypass
chmod 500 /tmp/mypass
openssl rand -base64 32 >> /tmp/mypass
aws s3 cp /tmp/mypass s3://$S3/Backup/passphrase.txt --sse aws:kms --sse-kms-key-id $KMS
rm /tmp/mypass
ln -s /root/openemr-devops/packages/standard/scripts/backup.sh /etc/cron.daily/duplicity-backups
ln -s /root/openemr-devops/packages/standard/scripts/restore.sh /root/restore.sh

cd /root/openemr-devops/packages/standard
if [ -z "$RECOVERYS3" ]; then
  # launch the CFN-supplied docker-compose.yaml
  ./docker-compose up --build -d
else
  # configure, but do not launch, OpenEMR docker
  ./docker-compose up --build --no-start
  # seed the target volumes with the stack backups
  # TODO: are there timing issues here? am I sure these volumes exist and won't be smashed?
  ./scripts/restore.sh -r import
  # okay, now go
  ./docker-compose up -d
fi
