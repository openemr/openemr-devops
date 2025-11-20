#!/bin/bash
# shellcheck disable=SC2154,SC2164,SC2312
set -o pipefail

# shellcheck source=/dev/null
source ./properties

displayHelp () {
cat <<EOF
Usage: $0 [... options] [-h | --help]

Restores your MariaDB database from backups created by this client. If run without
parameters, it will pick the most recent backup manifest in can find in the bind mount.

Backup artifacts include .gz files, healthcheck.cnf files, and .lsn directories, and
are prefaced by the timestamp of their creation.

Options:
    -m, --manifest FILE     A .manifest file referring to one or more backup
                            artifacts.

    -h, --help              Display this help message
EOF
    exit 0
}

pickLatestBackup() {
    TIMESTAMP=$(find . -maxdepth 1 -type f -name '*.manifest' -printf '%f\n' | \
        sort -r | head -n 1 | sed -E 's/(.*)\.manifest/\1/')
    if [[ $? -ne 0 || -z "${TIMESTAMP}" ]]; then
        echo "failure, cannot autodetect manifest"
    fi
}

validateManifest() {
    if [[ ! -f "${TIMESTAMP}.manifest" ]]; then
        echo "failure, cannot locate recovery manifest ${TIMESTAMP}"
        exit 1
    fi
}

openFullBackup() {
    mkdir -p /tmp/work/full
    gunzip -ck "${WORKINGTIMESTAMP}".gz | mbstream -x -C /tmp/work/full
    mariadb-backup --prepare --target-dir=/tmp/work/full
}

applyIncrementalBackup() {
    mkdir -p /tmp/work/partial
    gunzip -ck "${WORKINGTIMESTAMP}".gz | mbstream -x -C /tmp/work/partial
    mariadb-backup --prepare --target-dir=/tmp/work/full \
        --incremental-dir=/tmp/work/partial
    rm -rf /tmp/work/partial
}

processManifest() {
    set -e
    FULLBACKUPRUN=0
    while read -r WORKINGTIMESTAMP; do
        if [[ "${FULLBACKUPRUN}" -eq 0 ]]; then
            openFullBackup
            FULLBACKUPRUN=1
        else
            applyIncrementalBackup
        fi
        FINALTIMESTAMP="${WORKINGTIMESTAMP}"
    done <"${TIMESTAMP}".manifest
}

completeBackup() {
    if [[ -n "${DRYRUN}" ]]; then
        echo "dry-run specified, halting before wipe"
        return
    fi
    (cd /var/lib/mysql; rm -rf -- ..?* .[!.]* *)
    mariadb-backup --copy-back --target-dir=/tmp/work/full
    if [[ -f "${FINALTIMESTAMP}.my-healthcheck.cnf" ]]; then
        cp "${FINALTIMESTAMP}.my-healthcheck.cnf" /var/lib/mysql/.my-healthcheck.cnf
    fi;
    chown -R mysql:mysql /var/lib/mysql/
}

## Parse command-line options
OPTS=$(getopt -o hm: --long dry-run,manifest:,help -n 'restore.sh' -- "$@")
if [[ $? -ne 0 ]]; then
    echo "failure: couldn't parse options?" >&2
    exit 1
fi

## Reset the positional parameters to the parsed options
eval set -- "${OPTS}"

## Process the options
while true; do
  case "$1" in
    --dry-run)
      DRYRUN=1
      shift 1
      ;;
    -m | --manifest)
      TIMESTAMP=$(echo "$2" | sed -n -E 's/(.+)\.manifest/\1/p')
      if [[ $? -ne 0 || -z "${TIMESTAMP}" ]]; then
        echo "could not parse argument as manifest file"
        exit 1
      fi
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

cd "${BACKUPVOLUME_TARGET}"

if [[ -z "${TIMESTAMP}" ]]; then
    pickLatestBackup
fi

validateManifest
processManifest
completeBackup

echo restore complete, exiting recovery container

