#!/bin/sh

cd /var/www/localhost/htdocs/openemr
php ./unlock_admin.php -f $1
