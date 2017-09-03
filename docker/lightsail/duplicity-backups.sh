#!/bin/bash

duplicity --no-encryption --full-if-older-than 1M --include $(docker volume inspect docker_sitevolume | jq -r ".[0].Mountpoint") --exclude '**' / file:///root/backups/
duplicity remove-all-but-n-full 2 --force file:///root/backups/
