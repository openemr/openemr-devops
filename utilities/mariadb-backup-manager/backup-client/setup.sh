#!/bin/bash
# shellcheck disable=SC2154,SC2164,SC2312
set -o pipefail

# shellcheck source=/dev/null
source ./properties
# shellcheck source=/dev/null
source ./properties.secret

echo "[client]" > root-credentials.conf
chmod 600 root-credentials.conf

if [[ -n "${MARIADB_USER_FROMSCRIPT}" ]]; then
cat >> root-credentials.conf <<EOF
user="${MARIADB_USER_FROMSCRIPT}"
EOF
elif [[ -n "${MARIADB_USER}" ]]; then
cat >> root-credentials.conf <<EOF
user="${MARIADB_USER}"
EOF
elif [[ -n "${MYSQL_USER}" ]]; then
cat >> root-credentials.conf <<EOF
user="${MYSQL_USER}"
EOF
fi

if [[ -n "${MARIADB_PASSWORD_FROMSCRIPT}" ]]; then
cat >> root-credentials.conf <<EOF
password="${MARIADB_ROOT_PASSWORD}"
EOF
elif [[ -n "${MARIADB_PASSWORD_FROMSCRIPT}" ]]; then
cat >> root-credentials.conf <<EOF
password="${MARIADB_ROOT_PASSWORD}"
EOF
elif [[ -n "${MYSQL_ROOT_PASSWORD}" ]]; then
cat >> root-credentials.conf <<EOF
password="${MYSQL_ROOT_PASSWORD}"
EOF
elif [[ -n "${MARIADB_PASSWORD}" ]]; then
cat >> root-credentials.conf <<EOF
password="${MARIADB_PASSWORD}"
EOF
elif [[ -n "${MYSQL_PASSWORD}" ]]; then
cat >> root-credentials.conf <<EOF
password="${MYSQL_PASSWORD}"
EOF
fi

rm -f properties.secret
