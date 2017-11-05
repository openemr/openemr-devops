#!/bin/bash

# TODO: add getopts support, passthrough options for things like duplicity --time

source /root/cloud-variables
PASSPHRASE=$(aws s3 cp s3://$S3/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
export PASSPHRASE
duplicity --force s3://s3.amazonaws.com/$S3/Backup /
