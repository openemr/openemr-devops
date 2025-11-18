#!/bin/bash
# shellcheck disable=SC2154,SC2164,SC2312
set -o pipefail

# shellcheck source=/dev/null
source ./properties

CLIENTTARGET=/var/maria-recovery

getContainerID() {
    CONTAINER=$(docker compose -p "${PROJECT}" ps -a --format json | jq ' select(.Service="'"${SERVICENAME}"'") | .ID' -r)
    if [[ $? -ne 0 || -z "${CONTAINER}" ]]; then
        echo "failure, could not identify target container"
        exit 1
    fi
}

getContainerID
docker compose -p "${PROJECT}" stop --timeout 60
# shellcheck disable=SC2140
docker run --volumes-from "${CONTAINER}" -w "${CLIENTTARGET}" \
    --rm --mount type=bind,src="./restore-client",target="${CLIENTTARGET}" \
    "${IMAGE}" ./restore.sh "$@"
docker compose -p "${PROJECT}" start
