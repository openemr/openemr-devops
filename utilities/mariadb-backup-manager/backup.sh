#!/bin/bash
# shellcheck disable=SC2154,SC2164,SC2312
set -o pipefail

# shellcheck source=/dev/null
source ./properties

docker compose -p "${PROJECT}" exec -w "${CLIENTDIRECTORY}" "${SERVICENAME}" ./backup.sh
