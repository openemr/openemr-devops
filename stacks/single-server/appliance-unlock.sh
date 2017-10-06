#!/bin/bash

# /root/appliance-unlock.sh <new-admin-password>
# unlocks OpenEMR appliance and resets password if it has been locked prior to distribution
# *not* a general-purpose password recovery utility

sudo docker exec $(docker ps | grep openemr | cut -f 1 -d " ") /root/unlock_admin.sh $1
