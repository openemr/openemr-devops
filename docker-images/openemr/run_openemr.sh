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

    #do I need to activate mod_rewrite?
    echo "OpenEMR configured. Setting user 'www' as owner of openemr/ and setting file/dir permissions to 400/500"
    chown -Rf www .
    #set all directories to 500
    find . -type d -print0 | xargs -0 chmod 500
    #set all file access to 400
    find . -type f -print0 | xargs -0 chmod 400

    echo "Default file permissions and ownership set, allowing writing to specific directories"
    # Set file and directory permissions
    #chmod 666 sites/default/sqlconf.php why?
    chmod 600 interface/modules/zend_modules/config/application.config.php # should this actually be writable?
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
    # note for anyone using this: the 15s sleep delay is a bit of a footgun. It will (usually) delay attempted setup
    #    long enough for an accompanying mysql service container to come online (it takes a few seconds on the
    #    hardware we tested with. That being said, slower hardware or more complicated containers may take longer.
    #    If you find OpenEMR failing to set up (with the error shown below), this is why. Consider a more robust way
    #    of confirming mysql is running before openemr attempts configuration.
    sleep 15
    auto_setup || { echo "Couldn't set up. Perhaps MySQL wasn't ready for connection yet or credentials were incorrect?" && exit 1; }
fi

echo "Starting apache!"
/usr/sbin/httpd -D FOREGROUND
