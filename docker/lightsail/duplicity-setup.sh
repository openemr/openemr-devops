#!/bin/bash

mkdir /root/backups

cp duplicity-backups.sh /etc/cron.daily
chmod a+x /etc/cron.daily/duplicity-backups.sh
