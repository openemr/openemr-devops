#!/bin/bash

source /root/cloud-variables
PASSPHRASE=$(aws s3 cp s3://$S3/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
export PASSPHRASE
duplicity --full-if-older-than 7D --include $(docker volume inspect standard_sitevolume | jq -r ".[0].Mountpoint") --exclude '**' / s3://s3.amazonaws.com/$S3/Backup
duplicity remove-all-but-n-full 2 --force s3://s3.amazonaws.com/$S3/Backup
