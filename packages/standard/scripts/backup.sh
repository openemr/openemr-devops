#!/bin/bash

# shellcheck source=packages/standard/cloud-variables.stub
source /root/cloud-variables
PASSPHRASE=$(aws s3 cp "s3://${S3}/Backup/passphrase.txt" - --sse aws:kms --sse-kms-key-id "${KMS}")
export PASSPHRASE
VOLUME_INFO=$(docker volume inspect standard_sitevolume)
MOUNTPOINT=$(jq -r ".[0].Mountpoint" <<< "${VOLUME_INFO}")
duplicity --full-if-older-than 7D --include "${MOUNTPOINT}" --exclude '**' / "boto3+s3://${S3}/Backup"
duplicity remove-all-but-n-full 2 --force "boto3+s3://${S3}/Backup"
