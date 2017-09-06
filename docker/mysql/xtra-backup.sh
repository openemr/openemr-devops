#!/bin/bash

# TODO: use bash template to avoid hardcoded password
innobackupex --no-timestamp --password=root /mnt/backups | tee /mnt/backups/backup-logs.txt
innobackupex --apply-log --use-memory 25000000 /mnt/backups | tee --append /mnt/backups/backup-logs.txt
echo backup process complete!
