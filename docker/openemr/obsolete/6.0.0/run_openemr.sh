#!/bin/sh
# to be run by root with OpenEMR root dir as the CWD

sh autoconfig.sh

echo ""
echo "Love OpenEMR? You can now support the project via the open collective:"
echo " > https://opencollective.com/openemr/donate"
echo ""

echo "Starting cron daemon!"
crond
echo "Starting apache!"
/usr/sbin/httpd -D FOREGROUND
