#!/bin/bash

if [ $(date +%u) == 7 ]; then
  docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xbackup.sh -t full
else
  docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xbackup.sh -t incr
fi;
duplicity --no-encryption --full-if-older-than 7D --include $(docker volume inspect docker_sqlbackup | jq -r ".[0].Mountpoint") --include $(docker volume inspect docker_sitevolume | jq -r ".[0].Mountpoint") --exclude '**' / file:///root/backups/
duplicity remove-all-but-n-full 2 --force file:///root/backups/
