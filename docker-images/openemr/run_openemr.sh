#!/bin/sh

# allows customization of openemr credentials, preventing the need for manual setup
#  - Setting db parameters via MYSQL_HOST, MYSQL_USER, MYSQL_PASS
#  - Setting first-time account creation via OE_USER, OE_PASS
#  - All of these must be passed to automate the first-time setup process

CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
if [ "$CONFIG" == "0" ] && 
   [ "$MYSQL_HOST" != "" ] && 
   [ "$MYSQL_PASS" != "" ] &&
   [ "$MYSQL_ROOT_PASS" != "" ] &&
   [ "$MYSQL_USER" != "" ] &&
   [ "$OE_USER" != "" ] &&
   [ "$OE_PASS" != "" ]; then
    echo "Running quick setup!"
    php auto_configure.php -f iuser=$OE_USER iuserpass=$OE_PASS login=$MYSQL_USER rootpass=$MYSQL_ROOT_PASS pass=$MYSQL_PASS server=$MYSQL_HOST \
    || echo "Couldn't set up, trying again in 20 seconds.." && sleep 20 \
      && php auto_configure.php -f iuser=$OE_USER iuserpass=$OE_PASS login=$MYSQL_USER rootpass=$MYSQL_ROOT_PASS pass=$MYSQL_PASS server=$MYSQL_HOST \
    || echo "Couldn't set up, trying again in 20 seconds.." && sleep 20 \
      && php auto_configure.php -f iuser=$OE_USER iuserpass=$OE_PASS login=$MYSQL_USER rootpass=$MYSQL_ROOT_PASS pass=$MYSQL_PASS server=$MYSQL_HOST \
    || echo "Couldn't set up. Perhaps MySQL wasn't ready for connection yet or credentials were incorrect?" && exit 1
fi

/usr/sbin/httpd -D FOREGROUND