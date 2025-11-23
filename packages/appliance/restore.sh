#!/bin/bash
# shellcheck disable=SC2154,SC2312

# TODO: add getopts support, passthrough options for things like duplicity --time

userWarning() {
if [[ "$1" != "--confirm" ]]; then
cat <<EOF
*** WARNING ***

This tool will destructively restore your database and webroot.
Regardless of the success or failure of the restoration attempt,
all live records and state will be IRREVOCABLY DELETED.

It is recommended you make a full system snapshot and attempt this
recovery in a test copy or instance of this system before you proceed.

Please relaunch with --confirm when you are prepared to continue.

EOF
  exit 1
else
echo "restore.sh: confirmation acknowledged, beginning destructive restore ..."
fi
}

allocateSwap() {
  DR_SETSWAP=0
  # Historically, XtraBackup's incremental recovery mode requires a gig of free memory
  if [[ $(free --total --mega | grep Mem | awk '{ print $7 }') -lt 1024 ]]; then
    echo "recovery: low free memory, temporarily allocating swap space"
    if [[ $(swapon -s | grep -c 2GB.swap) -eq 1 ]]; then
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
}

userWarning "$1"

cd "$(dirname "$0")" || exit 1
docker compose stop

find "/opt/appliance/backups/in/site" -mindepth 1 -delete
find "/opt/appliance/backups/in/mysql" -mindepth 1 -delete

if [[ -f /root/recovery-restore-required ]]; then
  # shellcheck source=/dev/null
  source /root/cloud-variables
  S3=${RECOVERYS3}
  KMS=${RECOVERYKMS}
  PASSPHRASE=$(aws s3 cp s3://"${S3}"/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id "${KMS}")
  export PASSPHRASE
  duplicity --force boto3+s3://"${S3}"/Backup /opt/appliance/backups/in
  rm /root/recovery-restore-required
elif [[ -f /root/cloud-backups-enabled ]]; then
  S3=$(cat /root/.cloud-s3.txt)
  KMS=$(cat /root/.cloud-kms.txt)
  PASSPHRASE=$(aws s3 cp s3://"${S3}"/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id "${KMS}")
  export PASSPHRASE
  duplicity --force boto3+s3://"${S3}"/Backup /opt/appliance/backups/in
else
  duplicity --no-encryption --force file:///opt/appliance/backups/out /opt/appliance/backups/in
fi

allocateSwap

../../utilities/mariadb-backup-manager/restore.sh

if [[ "${DR_SETSWAP}" -eq 1 ]]; then
echo "postscript: reboot required to release allocated swap space"
fi
