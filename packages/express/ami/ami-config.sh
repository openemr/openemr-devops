#!/bin/sh

MYSQLROOTPWD="${1:-root}"

f () {
    cd /root
    curl -s https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/lightsail/launch.sh | bash -s -- -s 0    
    
    # wait a while for services to build    
    until docker container ls | grep openemr/openemr >& /dev/null
    do
        echo "waiting for container start..."
        sleep 5
    done

    until docker top $(docker ps | grep _openemr | cut -f 1 -d " ") | grep httpd &> /dev/null
    do
        echo "waiting for service start..."
        sleep 20
    done
    
    docker exec $(docker ps | grep mysql | cut -f 1 -d " ") mysql --password="$MYSQLROOTPWD" -e "update openemr.users set active=0 where id=1;"
    cp openemr-devops/packages/express/ami/ami-rekey.sh /etc/init.d/ami-rekey
    chmod 755 /etc/init.d/ami-rekey
    update-rc.d ami-rekey defaults
    rm -f /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys
    rm -f /home/ubuntu/.bash_history
    sync
    shutdown -h now
    exit 0
}

f
echo failure?
exit 1