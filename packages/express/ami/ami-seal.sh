#!/bin/bash

rm /root/.ssh/authorized_keys
rm /home/ubuntu/.ssh/authorized_keys
#rm /home/ubuntu/.bash_history
sync
shutdown -h now
