#!/usr/bin/env bash
# The check helpers are predicates: callers use them in if/&&/|| on
# purpose and handle a false result themselves.
# shellcheck disable=SC2310
#
# Run kubernetes/rotate-ca against the stack and verify the CA rotation
# end to end:
#
#   1. the data plane (OpenEMR HTTPS, MariaDB over mTLS, NFS-backed sites
#      volume; see probe-lib.sh) stays within its budget for the whole
#      rotation
#   2. the trust bundle, MariaDB's own CA bundle and every trust file
#      mounted in the workloads hold exactly the new CA
#   3. every leaf certificate is signed by the new CA, not the old one
#   4. a client certificate signed by the OLD CA is now rejected by Redis
#      and by MariaDB (the old CA is really gone), while the workloads'
#      own certificates still connect
#
# Usage: rotate-ca-test.sh [--max-gap SECONDS] [--timeout SECONDS]
#   --max-gap   Longest allowed gap between two successful samples of any
#               probe (default 60)
#   --timeout   Passed to rotate-ca as its per-wait timeout (default 900)
#
# Environment:
#   OPENEMR_HTTPS_URL   see probe-lib.sh
#   ROTATION_WORKDIR    Directory for probe logs (default: mktemp -d)
#
# Requires kubectl, cmctl, jq, openssl and curl on the caller's PATH.

set -euo pipefail

MAX_GAP=60
TIMEOUT=900
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-gap) MAX_GAP=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) sed -n '/^# Usage:/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
ROTATE_CA="${HERE}/../../kubernetes/rotate-ca"
WORKDIR=${ROTATION_WORKDIR:-$(mktemp -d)}
PROBE_DIR="${WORKDIR}/ca"
PROBE_TAG=ca
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

log() { echo "[ca] $*"; }
# shellcheck source=tests/kubernetes/probe-lib.sh
. "${HERE}/probe-lib.sh"
FAILED=0
fail() {
    echo "[ca] FAIL: $*"
    touch "${STOP_FILE}"
    wait 2>/dev/null || true
    exit 1
}
check_fail() { echo "[ca] FAIL: $*"; FAILED=1; }

fingerprint() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }
secret_field() {
    local key=${2//./\\.}
    kubectl get secret "$1" -o jsonpath="{.data.${key}}" | base64 -d
}
# SHA-256 fingerprints of every certificate in a PEM bundle on stdin,
# space separated.
bundle_fps() {
    local pem out=""
    pem=$(cat)
    while [[ "${pem}" == *"BEGIN CERTIFICATE"* ]]; do
        out="${out}$(openssl x509 -noout -fingerprint -sha256 <<< "${pem}" | cut -d= -f2) "
        pem=${pem#*END CERTIFICATE-----}
    done
    printf '%s\n' "${out% }"
}

# ---------------------------------------------------------------------------
# Keep the old CA (cert and key) to sign a test client certificate later.
# ---------------------------------------------------------------------------
secret_field ca-key-pair tls.crt > "${TMP}/old-ca.crt"
secret_field ca-key-pair tls.key > "${TMP}/old-ca.key"
OLD_FP=$(fingerprint < "${TMP}/old-ca.crt")
log "old CA ${OLD_FP}"

start_probes || fail "probes never reached a healthy baseline; stack was not healthy before rotation"

START_TS=$(date +%s)
bash "${ROTATE_CA}" --timeout "${TIMEOUT}" || fail "rotate-ca failed"
END_TS=$(date +%s)
log "rotate-ca took $((END_TS - START_TS))s"
sleep 8
stop_probes

secret_field ca-key-pair tls.crt > "${TMP}/new-ca.crt"
NEW_FP=$(fingerprint < "${TMP}/new-ca.crt")
[[ "${NEW_FP}" != "${OLD_FP}" ]] || fail "ca-key-pair still holds the old CA"
log "new CA ${NEW_FP}"

# ---------------------------------------------------------------------------
# Bundles and mounted trust files hold exactly the new CA.
# ---------------------------------------------------------------------------
# check_trust WHAT PEM: the PEM bundle holds exactly the new CA.
check_trust() {
    local what=$1 got
    got=$(bundle_fps <<< "$2")
    if [[ "${got}" = "${NEW_FP}" ]]; then
        log "PASS: ${what} trusts only the new CA"
    else
        check_fail "${what} holds [${got}], expected only the new CA"
    fi
}
pem=$(secret_field openemr-ca-bundle ca.crt || true)
check_trust "Secret openemr-ca-bundle" "${pem}"
pem=$(secret_field mysql-ca-bundle ca.crt || true)
check_trust "Secret mysql-ca-bundle (MariaDB)" "${pem}"

# workload  container  file...
TRUST_FILES=(
    "name=openemr|openemr|/redis-certs/redis-master-ca /redis-certs/redis-sentinel-ca /root/certs/mysql/server/mysql-ca ${SITES}/default/documents/certificates/mysql-ca"
    "name=phpmyadmin|phpmyadmin|/etc/mysql/ca.pem"
    "app=redis|redis|/certs/ca.crt"
    "app=sentinel|sentinel|/certs/ca.crt"
    "app=nfs-server|stunnel|/etc/stunnel/certs/ca.crt"
    "app=nfs-stunnel-client|stunnel|/etc/stunnel/certs/ca.crt"
)
for entry in "${TRUST_FILES[@]}"; do
    IFS='|' read -r sel container files <<< "${entry}"
    pods=$(ready_pods "${sel}")
    [[ -n "${pods}" ]] || { check_fail "no Ready pods for ${sel}"; continue; }
    for pod in ${pods}; do
        for f in ${files}; do
            pem=$(kubectl exec "${pod}" -c "${container}" -- cat "${f}" 2>/dev/null || true)
            check_trust "${pod}:${f}" "${pem}"
        done
    done
done

# ---------------------------------------------------------------------------
# Every leaf is signed by the new CA and not by the old one.
# ---------------------------------------------------------------------------
leaves=$(kubectl get certificates \
    -o jsonpath='{range .items[?(@.spec.issuerRef.name=="ca-issuer")]}{.metadata.name}{"="}{.spec.secretName}{"\n"}{end}')
for entry in ${leaves}; do
    secret_field "${entry#*=}" tls.crt > "${TMP}/leaf.crt"
    if openssl verify -CAfile "${TMP}/new-ca.crt" "${TMP}/leaf.crt" >/dev/null 2>&1 \
        && ! openssl verify -CAfile "${TMP}/old-ca.crt" "${TMP}/leaf.crt" >/dev/null 2>&1; then
        log "PASS: ${entry%%=*} is signed by the new CA"
    else
        check_fail "${entry%%=*} is not signed by the new CA"
    fi
done

# ---------------------------------------------------------------------------
# A client certificate signed by the old CA is rejected; the workloads'
# own certificates still work.
# ---------------------------------------------------------------------------
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=openemr" \
    -keyout "${TMP}/old-client.key" -out "${TMP}/old-client.csr" 2>/dev/null
openssl x509 -req -in "${TMP}/old-client.csr" -CA "${TMP}/old-ca.crt" -CAkey "${TMP}/old-ca.key" \
    -CAcreateserial -days 1 -out "${TMP}/old-client.crt" 2>/dev/null
POD=$(openemr_pod)
[[ -n "${POD}" ]] || fail "no Ready openemr pod"
for f in old-client.crt old-client.key; do
    kubectl exec -i "${POD}" -c openemr -- sh -c "cat > /tmp/${f}" < "${TMP}/${f}"
done

# Redis: a session with an accepted client certificate answers PING
# (-NOAUTH or +PONG); a rejected one gets no reply.
redis_answers() {
    local reply
    reply=$(kubectl exec "${POD}" -c openemr -- sh -c \
        "printf 'PING\\r\\n' | timeout 5 openssl s_client -connect redis-0.redis:6379 -cert $1 -key $2 -CAfile /redis-certs/redis-master-ca -verify_return_error -quiet -ign_eof 2>/dev/null; true") || return 1
    reply=${reply//[$'\r\n']/}
    [[ -n "${reply}" ]]
}
if redis_answers /redis-certs/redis-master-cert /redis-certs/redis-master-key; then
    log "PASS: Redis accepts OpenEMR's client certificate"
else
    check_fail "Redis rejects OpenEMR's client certificate"
fi
if redis_answers /tmp/old-client.crt /tmp/old-client.key; then
    check_fail "Redis still accepts a client certificate signed by the old CA"
else
    log "PASS: Redis rejects a client certificate signed by the old CA"
fi

# MariaDB: the openemr account is REQUIRE X509, so the login needs a
# client certificate MariaDB trusts.
mariadb_login() {
    timeout 15 kubectl exec "${POD}" -c openemr -- \
        mariadb -h mysql-primary -u openemr -popenemr \
            --ssl-ca=/root/certs/mysql/server/mysql-ca --ssl-cert="$1" --ssl-key="$2" \
            -e "SELECT 1" openemr >/dev/null 2>&1
}
if mariadb_login /root/certs/mysql/server/mysql-cert /root/certs/mysql/server/mysql-key; then
    log "PASS: MariaDB accepts OpenEMR's client certificate"
else
    check_fail "MariaDB rejects OpenEMR's client certificate"
fi
if mariadb_login /tmp/old-client.crt /tmp/old-client.key; then
    check_fail "MariaDB still accepts a client certificate signed by the old CA"
else
    log "PASS: MariaDB rejects a client certificate signed by the old CA"
fi
kubectl exec "${POD}" -c openemr -- rm -f /tmp/old-client.crt /tmp/old-client.key || true

# ---------------------------------------------------------------------------
# Data plane through the whole rotation.
# ---------------------------------------------------------------------------
check_probes "${START_TS}" "${END_TS}" "${MAX_GAP}" || FAILED=1
[[ "${FAILED}" = 0 ]] || exit 1
log "PASS: CA rotation verified (new CA everywhere, old CA rejected, data plane within ${MAX_GAP}s)"
