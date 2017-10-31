#!/bin/bash -xe

exec > /var/log/openemr-configure.log 2>&1

cd /root/openemr-devops/stacks/AWS-mktplace

# prepare the encrypted volume CFN just added
mkfs -t ext4 /dev/xvdd
mkdir /mnt/docker
chown 711 /mnt/docker
cat fstab.append >> /etc/fstab
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
ln -s /root/openemr-devops/stacks/AWS-mktplace/backup.sh /etc/cron.daily/duplicity-backups
ln -s /root/openemr-devops/stacks/AWS-mktplace/restore.sh /root/restore.sh

# launch the CFN-supplied docker-compose.yaml
cd /root/openemr-devops/stacks/AWS-mktplace
./docker-compose up --build -d
