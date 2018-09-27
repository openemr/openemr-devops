#!/bin/bash

WORKDIR=/mnt/backups/recovery

if service mysql status; then
  echo xrecovery-final: mysql must not be running, yet it is; aborting
  exit 1
fi

chown -R mysql:mysql $WORKDIR
rm -rf /mnt/backups/prerecovery-mysql-datadir
echo Copying prerecovery state...
mv -T /var/lib/mysql /mnt/backups/prerecovery-mysql-datadir
echo Moving restored database into position...
mv -T $WORKDIR /var/lib/mysql
echo Done, continuing...
rm -f /root/pending-restore
exit 0
