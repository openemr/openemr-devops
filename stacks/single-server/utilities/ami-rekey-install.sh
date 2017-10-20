#!/bin/sh

# installs service to rekey AMI after next boot

cp ami-rekey.sh /etc/init.d/ami-rekey
chkconfig --add ami-rekey
