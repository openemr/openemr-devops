#!/bin/bash

# TODO: add getopts support, passthrough options for things like duplicity --time

if [[ "$1" != "--confirm" ]]; then
  echo
  echo \*\*\* WARNING \*\*\*
  echo
  echo This tool will destructively restore your database and webroot.
  echo Regardless of the success or failure of the restoration attempt,
  echo all current patient information will be IRREVOCABLY DELETED.
  echo
  echo It is recommended you make a full system snapshot and attempt this
  echo recovery in a test copy or instance of this system before you proceed.
  echo
  echo Please relaunch with \'--confirm\' when you are prepared to continue.
  echo
  exit 1
else
  echo restore.sh: confirmation acknowledged, beginning destructive restore ...
fi

rm -rf $(docker volume inspect lightsail_sqlbackup | jq -r ".[0].Mountpoint")/*
rm -rf $(docker volume inspect lightsail_sitevolume | jq -r ".[0].Mountpoint")/*

if [ -f /root/recovery-restore-required ]; then
  source /root/cloud-variables
  S3=$RECOVERYS3
  KMS=$RECOVERYKMS
  PASSPHRASE=$(aws s3 cp s3://$S3/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
  export PASSPHRASE
  duplicity --force boto3+s3://$S3/Backup /  
elif [ -f /root/cloud-backups-enabled ]; then
  S3=$(cat /root/.cloud-s3.txt)
  KMS=$(cat /root/.cloud-kms.txt)
  PASSPHRASE=$(aws s3 cp s3://$S3/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
  export PASSPHRASE
  duplicity --force boto3+s3://$S3/Backup /
else
  duplicity --no-encryption --force file:///root/backups /
fi

if [[ $(dpkg --print-architecture) =~ arm ]]; then
  echo File system restored, skipping unavailable arm DB restore
  exit 0
fi

DR_SETSWAP=0
# Xtrabackup's incremental recovery mode requires a gig of free memory -- go ahead and find /that/ in the docs. Ugh.
if [[ $(free --total --mega | grep Total | awk '{ print $4 }') -lt 1024 ]]; then
  echo recovery: low free memory, temporarily allocating swap space
  if [[ $(swapon -s | grep 2GB.swap | wc -l) -eq 1 ]]; then
    # disaster, it's already on
    echo "warning: insufficent memory to proceed with restore, but swap is already allocated?"
    echo "         ... will attempt to proceed anyways, but success is unlikely"
  else
    DR_SETSWAP=1
    fallocate -l 2G /mnt/2GB.swap
    if [[ $? -ne 0 ]]; then
      echo "warning: unable to allocate swap, backup may not succeed"
    else
      chmod 600 /mnt/2GB.swap
      mkswap /mnt/2GB.swap
      swapon /mnt/2GB.swap
    fi
  fi
fi

docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xrecovery.sh -m 125M

if [[ $DR_SETSWAP -eq 1 ]]; then
  echo
  echo ------------
  echo DIRE WARNING
  echo ------------
  echo
  echo Your free memory was too low to complete the backup without unusual measures,
  echo so I allocated extra swap space. Rebooting will release that swap space, and
  echo this is necessary because you may incur significant long-term I/O expenses if
  echo you\'re operating in AWS LightSail or EC2 and you leave swap activated. Please
  echo do not forget to reboot this instance and delete /mnt/2GB.swap as soon as
  echo practical.
  echo
fi
