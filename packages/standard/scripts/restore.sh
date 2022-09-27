#!/bin/bash

# TODO: add passthrough options for things like duplicity --time

RECOVERYMODE=local

while getopts "r:" opt; do
  case $opt in
    r)
      RECOVERYMODE=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

source /root/cloud-variables

case $RECOVERYMODE in
  local)
    BUCKET=$S3
    ;;
  import)
    BUCKET=$RECOVERYS3
    ;;
  \?)
    echo "Invalid option: -r " $RECOVERYMODE >&2
    exit 1
    ;;
esac

PASSPHRASE=$(aws s3 cp s3://$BUCKET/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
export PASSPHRASE
duplicity --force boto3+s3://$BUCKET/Backup /
