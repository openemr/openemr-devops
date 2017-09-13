#!/bin/bash

WORKDIR=/mnt/backups/recovery

if service mysql status; then
  echo xrecovery-final: mysql must not be running, yet it is; aborting
  exit 1
fi

rm -f /root/pending-restore
chown -R mysql:mysql $WORKDIR
rm -rf /mnt/backups/prerecovery-mysql-datadir
mv /var/lib/mysql /mnt/backups/prerecovery-mysql-datadir
mv $WORKDIR /var/lib/mysql
exit 0
