#!/bin/bash
# shellcheck disable=SC2154,SC2164,SC2312
set -o pipefail

# shellcheck source=/dev/null
source ./properties

TIMESTAMP="$(date +%Y-%m-%d-%H-%M-%S)"

BACKUPCLASS=undecided
considerState() {
    LASTFULLBACKUP="$(find "${BACKUPVOLUME_TARGET}" -maxdepth 1 -type f -name '*.manifest' -printf '%f\n' | \
        sort -r | head -n 1 | sed -E "s/(.*)\.manifest/\1/")"
    if [[ $? -ne 0 || -z "${LASTFULLBACKUP}" ]]; then
        echo "can't find valid manifest, was this expected?"
        BACKUPCLASS=full
        return
    fi
    if [[ "$(wc -l "${BACKUPVOLUME_TARGET}"/"${LASTFULLBACKUP}".manifest | awk '{print $1}')" -ge "${INCREMENTALS}" ]]; then
        echo "incrementals have cycled, running full backup"
        BACKUPCLASS=full
        return
    fi
    BACKUPCLASS=incremental
    LASTBACKUP="$(tail -n 1 "${BACKUPVOLUME_TARGET}"/"${LASTFULLBACKUP}".manifest)"
    if [[ $? -ne 0 || -z "${LASTBACKUP}" ]]; then
        echo "something's wrong with this manifest? running full backup..."
        BACKUPCLASS=full
    fi
}

# I can't believe we have to do this
grabCurrentHealthcheck() {
    if [[ -e /var/lib/mysql/.my-healthcheck.cnf ]]; then
        cp /var/lib/mysql/.my-healthcheck.cnf "${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}".my-healthcheck.cnf
    fi
}

runFullBackup() {
    mkdir "${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}"-lsn
    grabCurrentHealthcheck
    mariadb-backup --defaults-extra-file=root-credentials.conf --backup --stream=xbstream \
        --extra-lsndir="${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}"-lsn | gzip > "${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}".gz
    if [[ $? == 0 ]]; then
        echo "${TIMESTAMP}" > "${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}".manifest
    else
        echo "--- WARNING WARNING WARNING ---"
        echo "full backup attempt ${TIMESTAMP} failure, review logs"
        echo "--- WARNING WARNING WARNING ---"
        exit 1
    fi  
}

runIncrementalBackup() {
    mkdir "${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}"-lsn
    grabCurrentHealthcheck
    mariadb-backup --defaults-extra-file=root-credentials.conf --backup --stream=xbstream \
        --incremental-basedir="${BACKUPVOLUME_TARGET}"/"${LASTBACKUP}-lsn" \
        --extra-lsndir="${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}"-lsn | gzip > "${BACKUPVOLUME_TARGET}"/"${TIMESTAMP}".gz
    if [[ $? == 0 ]]; then
        echo "${TIMESTAMP}" >> "${BACKUPVOLUME_TARGET}"/"${LASTFULLBACKUP}".manifest
    else
        echo "--- WARNING WARNING WARNING ---"
        echo "incremental backup attempt ${TIMESTAMP} failure, review logs"
        echo "--- WARNING WARNING WARNING ---"
        exit 1
    fi  
}

runBackup() {
    if [[ "${BACKUPCLASS}" == "full" ]]; then
        runFullBackup
    elif [[ "${BACKUPCLASS}" == "incremental" ]]; then
        runIncrementalBackup
    else
        echo "warning, backups in unexpected state"
        exit 1
    fi
}

pruneOldBackups() {
    # up until now I've avoided changing directories, but this is the last stop and where we're deleting files
    # so let's not make it harder
    cd "${BACKUPVOLUME_TARGET}" || exit 1
    TARGET_MANIFEST=$(find . -maxdepth 1 -type f -name '*.manifest' -printf '%f\n' | sort -r | \
        sed "$((CYCLES_TO_KEEP+1))"'q;d' | sed -E "s/(.*)\..*/\1/")
    if [[ $? -ne 0 || -z "${TARGET_MANIFEST}" ]]; then
        return
    fi
    find . -maxdepth 1 | sort |  awk '$0 < "./'"${TARGET_MANIFEST}"'"' | sed 1d | xargs -r -- rm -rf
}

considerState
runBackup
pruneOldBackups
