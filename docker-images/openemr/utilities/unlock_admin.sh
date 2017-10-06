#!/bin/sh

cd /var/www/localhost/htdocs/openemr
php ./unlock-admin.php -f $1
