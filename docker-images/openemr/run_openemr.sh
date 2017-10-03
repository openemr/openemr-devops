#!/bin/sh
# to be run by root with OpenEMR root dir as the CWD

# allows customization of openemr credentials, preventing the need for manual setup
#  - Required settings are MYSQL_HOST and MYSQL_ROOT_PASS
#  -  (note that can force MYSQL_ROOT_PASS to be empty by passing as `BLANK` variable)
#  - Optional settings:
#    - MANUAL_SETUP ('yes' will force manual setup)
#    - Setting db parameters MYSQL_USER, MYSQL_PASS, MYSQL_DATABASE
#    - Setting openemr parameters OE_USER, OE_PASS
set -e

auto_setup() {

    CONFIGURATION="server=${MYSQL_HOST} rootpass=${MYSQL_ROOT_PASS} loginhost=%"
    if [ "$MYSQL_USER" != "" ]; then
        CONFIGURATION="${CONFIGURATION} login=${MYSQL_USER}"
    fi
    if [ "$MYSQL_PASS" != "" ]; then
        CONFIGURATION="${CONFIGURATION} pass=${MYSQL_PASS}"
    fi
    if [ "$MYSQL_DATABASE" != "" ]; then
        CONFIGURATION="${CONFIGURATION} dbname=${MYSQL_DATABASE}"
    fi
    if [ "$OE_USER" != "" ]; then
        CONFIGURATION="${CONFIGURATION} iuser=${OE_USER}"
    fi
    if [ "$OE_PASS" != "" ]; then
        CONFIGURATION="${CONFIGURATION} iuserpass=${OE_PASS}"
    fi

    chmod -R 600 .
    php auto_configure.php -f ${CONFIGURATION} || return 1

    echo "OpenEMR configured. Setting user 'www' as owner of openemr/ and setting file/dir permissions to 400/500"
    #set all directories to 500
    find . -type d -print0 | xargs -0 chmod 500
    #set all file access to 400
    find . -type f -print0 | xargs -0 chmod 400

    echo "Default file permissions and ownership set, allowing writing to specific directories"
    chmod 700 run_openemr.sh
    # Set file and directory permissions
    chmod 600 interface/modules/zend_modules/config/application.config.php
    find sites/default/documents -type d -print0 | xargs -0 chmod 700
    find sites/default/edi -type d -print0 | xargs -0 chmod 700
    find sites/default/era -type d -print0 | xargs -0 chmod 700
    find sites/default/letter_templates -type d -print0 | xargs -0 chmod 700
    find interface/main/calendar/modules/PostCalendar/pntemplates/cache -type d -print0 | xargs -0 chmod 700
    find interface/main/calendar/modules/PostCalendar/pntemplates/compiled -type d -print0 | xargs -0 chmod 700
    find gacl/admin/templates_c -type d -print0 | xargs -0 chmod 700

    echo "Removing remaining setup scripts"
    #remove all setup scripts
    rm acl_setup.php
    rm acl_upgrade.php
    rm setup.php
    rm sql_upgrade.php
    rm ippf_upgrade.php
    rm gacl/setup.php
    rm auto_configure.php
    echo "Setup scripts removed, we should be ready to go now!"
}

CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
if [ "$CONFIG" == "0" ] &&
   [ "$MYSQL_HOST" != "" ] &&
   [ "$MYSQL_ROOT_PASS" != "" ] &&
   [ "$MANUAL_SETUP" != "yes" ]; then

    echo "Running quick setup!"
    while ! auto_setup; do
        echo "Couldn't set up. Any of these reasons could be what's wrong:"
        echo " - You didn't spin up a MySQL container or connect your OpenEMR container to a mysql instance"
        echo " - MySQL is still starting up and wasn't ready for connection yet"
        echo " - The Mysql credentials were incorrect"
        sleep 1;
    done
    echo "Setup Complete!"
fi

echo "Starting apache!"
/usr/sbin/httpd -D FOREGROUND
