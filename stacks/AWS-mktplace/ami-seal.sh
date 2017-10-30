#!/bin/bash

rm /root/.ssh/authorized_keys
rm /home/ubuntu/.ssh/authorized_keys
# should I delete bash histories here?
sync
shutdown -h now
