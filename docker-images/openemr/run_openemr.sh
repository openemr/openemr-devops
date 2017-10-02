#!/bin/sh
# to be run by root with OpenEMR root dir as the CWD

# allows customization of openemr credentials, preventing the need for manual setup
#  - Setting db parameters via MYSQL_HOST, MYSQL_USER, MYSQL_PASS
#  - Setting first-time account creation via OE_USER, OE_PASS
#  - All of these must be passed to automate the first-time setup process
set -e

auto_setup() {
    chmod -R 600 .
    php auto_configure.php -f \
        iuser=$OE_USER \
        iuserpass=$OE_PASS \
        login=$MYSQL_USER \
        rootpass=$MYSQL_ROOT_PASS \
        pass=$MYSQL_PASS \
        server=$MYSQL_HOST \
    || return 1

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
   [ "$MYSQL_PASS" != "" ] &&
   [ "$MYSQL_ROOT_PASS" != "" ] &&
   [ "$MYSQL_USER" != "" ] &&
   [ "$OE_USER" != "" ] &&
   [ "$OE_PASS" != "" ]; then
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
