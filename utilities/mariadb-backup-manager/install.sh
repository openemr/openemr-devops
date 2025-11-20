#!/bin/bash
# shellcheck disable=SC2154,SC2164,SC2312
set -o pipefail

displayHelp () {
cat <<EOF
Usage: $0 [... options] [-h | --help]

Initializes and installs the MariaDB incremental backup and recovery client to your
MariaDB-based docker-compose project.

Required:
    --database-volume NAME  name of volume assigned to the MariaDB data directory
    --backup-volume NAME    name of volume for backup workspace operations
    --client-directory DIR  location client should be installed to

Options:
    -p, --project NAME      name of your project, assigned by compose
                            often the name of the directory containing the compose yaml
    -i, --image IMAGE       name of the MariaDB container repo image, with version tag
    -c, --container NAME    name of the created container in the project
    -s, --service NAME      name of the configured service from the compose yaml

    --mariadb-user USER     MySQL root-equivalent user for backup access
    --mariadb-password PASS MySQL account password

    --cycles NUMBER         number of completed full backups to keep before purge
    --incrementals NUMBER   number of incrementals per backup cycle

    -h, --help              Display this help message

Note:
    Many settings will be autodetected and don't need to be set. If you have one running project
    with one instance of MariaDB, all you need are the volume identifiers and client target.

    You must have a backup-volume assigned for our workspace, but you can skip sharing it with 
    the host if you don't plan to exfiltrate backups offsite. 

EOF
    exit 0
}

identifyProject () {
    if [[ -z "${PROJECT}" ]]; then
        if [[ ! "$(docker compose ls -q | wc -l)" == 1 ]]; then
            echo "failure: cannot identify project"
            exit 1
        fi
        PROJECT="$(docker compose ls -q)"
    fi
    PROJECT_YAML=$(docker compose ls --filter NAME="${PROJECT}" | awk 'NR==2 {print $3}')
}

identifyContainerImage () {
    if [[ -z "${IMAGE}" ]]; then
        IMAGE=$(docker compose -p "${PROJECT}" ps | grep mariadb | awk '{print $2}' | head -n 1)
        if [[ $? -ne 0 || -z "${IMAGE}" ]]; then
            echo "failure: cannot identify MariaDB image"
            exit 1
        fi
    fi
}

identifyDatabaseContainer () {
    if [[ -z "${CONTAINER}" ]]; then
        CONTAINER=$(docker compose -p "${PROJECT}" ps | grep "${IMAGE}" | awk '{print $1}' | head -n 1)
        if [[ $? -ne 0 || -z "${CONTAINER}" ]]; then
            echo "failure: cannot identify MariaDB container"
            exit 1
    fi    fi
}

identifyDatabaseServiceName () {
    if [[ -z "${SERVICENAME}" ]]; then
        SERVICENAME=$(docker compose -p "${PROJECT}" ps | grep "${CONTAINER}" | awk '{print $4}' | head -n 1)
        if [[ $? -ne 0 || -z "${SERVICENAME}" ]]; then
            echo "failure: cannot identify compose service name"
            exit 1
        fi
    fi
}

validateClientDirectory () {
    if [[ -z "${CLIENTDIRECTORY}" ]]; then
        echo "failure, no client directory for container ageny supplied"
        exit 1
    fi

}

validateDatabaseVolume() {
    if [[ -z "${DATABASEVOLUME}" ]]; then
        echo "failure: compose volume for database must be provided"
        exit 1
    fi
    # shellcheck disable=SC2046
    DATABASEVOLUME_CANONICAL="$(docker volume inspect $(docker volume ls | awk 'NR>1 {print $2}') | \
        jq '.[] | select(.Labels["com.docker.compose.volume"]=="'"${DATABASEVOLUME}"'" and .Labels["com.docker.compose.project"]=="'"${PROJECT}"'") | .Name' -r)"
    if [[ $? -ne 0 || -z "${DATABASEVOLUME_CANONICAL}" ]]; then
        echo "failure: could not locate canonical volume name for database volume"
        exit 1
    fi
}

validateBackupVolume() {
    if [[ -z "${BACKUPVOLUME}" ]]; then
        echo "failure: compose volume for backup must be provided"
        exit 1
    fi
    # shellcheck disable=SC2046
    BACKUPVOLUME_CANONICAL="$(docker volume inspect $(docker volume ls | awk 'NR>1 {print $2}') | \
        jq '.[] | select(.Labels["com.docker.compose.volume"]=="'"${BACKUPVOLUME}"'" and .Labels["com.docker.compose.project"]=="'"${PROJECT}"'") | .Name' -r)"
    if [[ $? -ne 0 || -z "${BACKUPVOLUME_CANONICAL}" ]]; then
        echo "failure: could not locate canonical volume name for backup volume"
        exit 1
    fi
    BACKUPVOLUME_TARGET=$(docker compose -f "${PROJECT_YAML}" config --format json | \
        jq '.services.'"${SERVICENAME}"'.volumes | .[] | select(.source=="'"${BACKUPVOLUME}"'").target' -r)
    if [[ $? -ne 0 || -z "${BACKUPVOLUME_TARGET}" ]]; then
        echo "failure: could not locate internal target for backup volume"
        exit 1
    fi
}

writeEnvironments() {
cat > properties <<EOF
PROJECT="${PROJECT}"
PROJECT_YAML=${PROJECT_YAML}
IMAGE="${IMAGE}"
CONTAINER="${CONTAINER}"
SERVICENAME="${SERVICENAME}"
CLIENTDIRECTORY="${CLIENTDIRECTORY}"
DATABASEVOLUME="${DATABASEVOLUME}"
DATABASEVOLUME_CANONICAL="${DATABASEVOLUME_CANONICAL}"
BACKUPVOLUME="${BACKUPVOLUME}"
BACKUPVOLUME_CANONICAL="${BACKUPVOLUME_CANONICAL}"
BACKUPVOLUME_TARGET="${BACKUPVOLUME_TARGET}"
EOF
chmod 600 properties

cat > backup-client/properties <<EOF
CYCLES_TO_KEEP="${CYCLES_TO_KEEP}"
INCREMENTALS="${INCREMENTALS}"
BACKUPVOLUME_TARGET="${BACKUPVOLUME_TARGET}"
EOF
chmod 600 backup-client/properties

touch backup-client/properties.secret
if [[ -n "${MARIADB_USER}" ]]; then
cat >> backup-client/properties.secret <<EOF
MARIADB_USER_FROMSCRIPT="${MARIADB_USER}"
EOF
fi
if [[ -n "${MARIADB_PASSWORD}" ]]; then
cat >> backup-client/properties.secret <<EOF
MARIADB_PASSWORD_FROMSCRIPT="${MARIADB_PASSWORD}"
EOF
fi
chmod 600 backup-client/properties.secret

cat > restore-client/properties <<EOF
BACKUPVOLUME_TARGET="${BACKUPVOLUME_TARGET}"
EOF
chmod 600 restore-client/properties

}


installClient () {
    
    (cd backup-client && docker compose -p "${PROJECT}" cp ./ "${SERVICENAME}":"${CLIENTDIRECTORY}")
    if [[ ! $? == 0 ]]; then
        echo "failure, error writing client to container"
        exit 1
    fi
    docker compose -p "${PROJECT}" exec "${SERVICENAME}" sh -c 'chmod 400 '"${CLIENTDIRECTORY}"'/properties*'
    rm -f backup-client/properties backup-client/properties.secret
    docker compose -p "${PROJECT}" exec "${SERVICENAME}" sh -c 'chmod 500 '"${CLIENTDIRECTORY}"'/*.sh'
    docker compose -p "${PROJECT}" exec -w "${CLIENTDIRECTORY}" "${SERVICENAME}" ./setup.sh  

    chmod a+x -- *.sh restore-client/restore.sh
}

CYCLES_TO_KEEP=3
INCREMENTALS=6

# honestly I may take these out in production
DATABASEVOLUME=databasevolume
BACKUPVOLUME=databasebackupvolume
CLIENTDIRECTORY=/opt/mysqlbak/bin

## Parse command-line options
OPTS=$(getopt -o p:i:c:s:h --long project:,image:,container:,service:,database-volume:,backup-volume:,cycles:,incrementals:,client-directory:,mariadb-user:,mariadb-password:,help -n 'install.sh' -- "$@")

if [[ $? -ne 0 ]]; then
    echo "failure: couldn't parse options?" >&2
    exit 1
fi

## Reset the positional parameters to the parsed options
eval set -- "${OPTS}"

## Process the options
while true; do
  case "$1" in
    -p | --project)
      PROJECT="$2"
      shift 2
      ;;
    -i | --image)
      IMAGE="$2"
      shift 2
      ;;
    -c | --container)
      CONTAINER="$2"
      shift 2
      ;;
    -s | --service)
      SERVICENAME="$2"
      shift 2
      ;;
    --database-volume)
      DATABASEVOLUME="$2"
      shift 2
      ;;
    --backup-volume)
      BACKUPVOLUME="$2"
      shift 2
      ;;
    --client-directory)
      CLIENTDIRECTORY="$2"
      shift 2
      ;;
    --cycles)
      CYCLES_TO_KEEP="$2"
      shift 2
      ;;
    --incrementals)
      INCREMENTALS="$2"
      shift 2
      ;;
    --mariadb-user)
      MARIADB_USER="$2"
      shift 2
      ;;
    --mariadb-password)
      MARIADB_PASSWORD="$2"
      shift 2
      ;;
    -h | --help)
      displayHelp
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "failure: internal error parsing options"
      exit 1
      ;;
  esac
done

identifyProject
identifyContainerImage
identifyDatabaseContainer
identifyDatabaseServiceName
validateDatabaseVolume
validateBackupVolume
writeEnvironments
installClient
