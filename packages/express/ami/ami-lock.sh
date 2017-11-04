#!/bin/bash

# lock AMI prior to freezing to prevent external access prior to rekeying
# manual entry of MySQL root password is required

docker exec -it $(docker ps | grep mysql | cut -f 1 -d " ") mysql -p -e "update openemr.users set active=0 where id=1;"
cp ami-rekey.sh /etc/init.d/ami-rekey
update-rc.d ami-rekey defaults
