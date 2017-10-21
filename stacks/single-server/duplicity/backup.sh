#!/bin/bash

docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xbackup-wrapper.sh
duplicity --no-encryption --full-if-older-than 9D --include $(docker volume inspect singleserver_sqlbackup | jq -r ".[0].Mountpoint") --include $(docker volume inspect singleserver_sitevolume | jq -r ".[0].Mountpoint") --exclude '**' / file:///root/backups/
duplicity remove-all-but-n-full 2 --force file:///root/backups/
