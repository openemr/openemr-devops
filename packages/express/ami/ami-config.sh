#!/bin/sh

set -e
MYSQLROOTPWD="${1:-root}"

f () {
    cd /root
    curl -s https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/lightsail/launch.sh | bash -s -- -s 0

    # wait a while for services to build
    until docker container ls | grep -q openemr/openemr
    do
        echo "waiting for container start..."
        sleep 5
    done

    # shellcheck disable=SC2312
    until docker top "$(docker ps | grep -openemr | cut -f 1 -d " ")" | grep httpd -q
    do
        echo "waiting for service start..."
        sleep 20
    done

    docker compose exec mysql mysql --password="${MYSQLROOTPWD}" -e "update openemr.users set active=0 where id=1;"
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
