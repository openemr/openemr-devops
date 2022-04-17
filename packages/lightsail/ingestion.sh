#!/bin/bash

# Some notes.
# One: We do not try to handle multisite, and we assume your openemr DB is named openemr. Will make that a parameter later.
# Two: Current I target only the sites directory, which may leave customization behind. You'll want to extend this recovery to
#      pick up those changes (and maybe rerun composer?) but I'm not familiar with that part. I just know copying node_modules
#      *has* to be the wrong decision.
# Three: You'll want a /lot/ of room to unpack. An eight-gig instance won't cut it.

mkdir /tmp/backup-ingestion
cd /tmp/backup-ingestion
tar -xf $1 -C /tmp/backup-ingestion/ --no-same-owner

DOCKERID=$(docker ps | grep _openemr | cut -f 1 -d " ")

# retrieve site
mkdir webroot
tar -zxf openemr.tar.gz -C webroot
rm openemr.tar.gz
find webroot -type d -name 'node_modules' -exec rm -rf {} +
docker cp $DOCKERID:/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php webroot/sites/default
docker cp webroot $DOCKERID:/tmp/oe-recovery

# straighten out internal permissions
docker exec -i $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh -s << "EOF"
cd /var/www/localhost/htdocs/openemr/sites
chown -R apache:root default-recovery
chmod -R 400 default-recovery
chmod 500 default-recovery
chmod -R 500 default-recovery/LBF default-recovery/images
chmod -R 700 default-recovery/documents
mv default /root/default-old
mv default-recovery default
EOF

# restore database
gzip -d openemr.sql.gz
echo 'USE openemr;' | cat - openemr.sql | docker exec -i $DOCKERID /bin/sh -c 'mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS"'
rm openemr.sql

# swift kick to PHP
docker restart $DOCKERID

cd /root
rm -rf /tmp/backup-ingestion

echo Restore operation complete!
