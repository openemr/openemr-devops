#!/bin/bash

/root/openemr-devops/utilities/mariadb-backup-manager/backup.sh

if [[ -f /root/cloud-backups-enabled ]]; then
  S3=$(cat /root/.cloud-s3.txt)
  KMS=$(cat /root/.cloud-kms.txt)
  PASSPHRASE=$(aws s3 cp s3://"${S3}"/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id "${KMS}")
  export PASSPHRASE
  duplicity --full-if-older-than 7D /opt/appliance/backups/in boto3+s3://"${S3}"/Backup
  duplicity remove-all-but-n-full 2 --force boto3+s3://"${S3}"/Backup
else
  duplicity --no-encryption --full-if-older-than 7D /opt/appliance/backups/in file:///opt/appliance/backups/out
  duplicity remove-all-but-n-full 2 --force file:///opt/appliance/backups/out
fi
