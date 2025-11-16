#!/bin/bash
set -o pipefail

source ./properties

docker compose -p "${PROJECT}" exec -w "${CLIENTDIRECTORY}" ${SERVICENAME} ./backup.sh
