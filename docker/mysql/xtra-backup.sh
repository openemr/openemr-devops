#!/bin/bash

echo this is terrible! don't use it!
exit 1

# TODO: use bash template to avoid hardcoded password
# TODO should some of these be xtrabackup calls?
# TODO: adopt https://github.com/dotmanila/mootools/blob/master/xbackup.sh
innobackupex --no-timestamp --password=root /mnt/backups | tee /mnt/backups/backup-logs.txt
innobackupex --apply-log --use-memory 25000000 /mnt/backups | tee --append /mnt/backups/backup-logs.txt
echo backup process complete!
