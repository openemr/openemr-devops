#!/bin/bash

echo ### WARNING ###
echo
echo This tool will destructively recover your webroot. Test its behavior in a snapshot before continuing. Edit this file to proceed.
exit 1

duplicity --no-encryption --force file:///root/backups /
