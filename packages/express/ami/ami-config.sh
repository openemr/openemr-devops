#!/bin/bash

set -e

f () {
    # shellcheck disable=SC2312
    curl -s https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/appliance/launch.sh | bash -s --

    until [[ -n "${CONTAINER}" ]]
    do
        echo "waiting on composer start..."
        sleep 5
        CONTAINER="$(docker compose -p appliance ps --services openemr -qa)"
    done

    # shellcheck disable=SC2312
    until [[ "$(docker container inspect "${CONTAINER}" | jq '.[].State.Health.Status' -r)" == "healthy" ]]
    do
        echo "waiting on service start..."
        sleep 5
    done

    # lockout default admin, set password as instance ID on next boot
    docker compose -p appliance exec mysql sh -c 'mariadb --password=${MYSQL_ROOT_PASSWORD} -e "update openemr.users set active=0 where id=1;"'
    cd openemr-devops/packages/express/ami
    cp ami-rekey.sh /etc/init.d/ami-rekey
    chmod 755 /etc/init.d/ami-rekey
    update-rc.d ami-rekey defaults
}

f
