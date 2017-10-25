#!/bin/bash

docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xbackup-wrapper.sh

if [ -f /root/cloud-backups-enabled ]; then
  S3=$(cat /root/.cloud-s3.txt)
  KMS=$(cat /root/.cloud-kms.txt)
  PASSPHRASE=$(aws s3 cp s3://$S3/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
  export PASSPHRASE
  duplicity --full-if-older-than 9D --include $(docker volume inspect singleserver_sqlbackup | jq -r ".[0].Mountpoint") --include $(docker volume inspect singleserver_sitevolume | jq -r ".[0].Mountpoint") --exclude '**' / s3://s3.amazonaws.com/$S3/Backup
  duplicity remove-all-but-n-full 2 --force s3://s3.amazonaws.com/$S3/Backup
else
  duplicity --no-encryption --full-if-older-than 9D --include $(docker volume inspect singleserver_sqlbackup | jq -r ".[0].Mountpoint") --include $(docker volume inspect singleserver_sitevolume | jq -r ".[0].Mountpoint") --exclude '**' / file:///root/backups/
  duplicity remove-all-but-n-full 2 --force file:///root/backups/
fi
