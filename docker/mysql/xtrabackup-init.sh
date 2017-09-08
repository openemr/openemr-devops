#!/bin/bash

exec > /tmp/xtrabackup-launch.log 2>&1

echo xtrabackup-init: first time setup of xtrabackup
cd /root
./xbackup.sh -a
./xbackup.sh -t full
