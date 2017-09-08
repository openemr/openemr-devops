#!/bin/bash

echo xtrabackup-init: first time setup of xtrabackup
cd /root
./xbackup.sh -a
./xbackup.sh -t full
