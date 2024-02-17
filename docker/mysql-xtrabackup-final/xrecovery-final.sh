#!/bin/bash

WORKDIR=/mnt/backups/recovery

if service mysql status; then
  echo xrecovery-final: mysql must not be running, yet it is; aborting
  exit 1
fi

# Even though MySQL isn't running, I can't just make off with /var/lib/mysql,
# since the container mounts it.

chown -R mysql:mysql $WORKDIR
rm -rf /mnt/backups/prerecovery-mysql-datadir
echo Copying prerecovery state...
mkdir /mnt/backups/prerecovery-mysql-datadir
mv /var/lib/mysql/* /mnt/backups/prerecovery-mysql-datadir
echo Moving restored database into position...
mv -v $WORKDIR/* /var/lib/mysql
echo Done, continuing...
rm -f /root/pending-restore
touch /root/force-full-backup
touch /root/restore-process-complete
exit 0
