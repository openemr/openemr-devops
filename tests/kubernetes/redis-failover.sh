#!/usr/bin/env bash
# The query helpers are used as conditions on purpose; callers handle a
# failed query by retrying or failing with a message.
# shellcheck disable=SC2310
#
# Kill the current Redis master and verify Sentinel fails over:
#   1. Sentinel names a different master within the timeout
#   2. the deleted pod comes back as a replica of the new master with its
#      replication link up (not a replica of itself)
#   3. every Sentinel agrees on the master and knows exactly the other
#      Sentinels as peers (no dead peers left over from restarts)
#   4. OpenEMR still answers through its Redis-backed sessions
#
# Run after the Sentinel and Redis certificate rotations: those restart
# every Sentinel / Redis pod, which is what used to leave stale Sentinel
# peers (blocking the election) and self-replicating Redis pods.
#
# Environment:
#   OPENEMR_HTTPS_URL  Login page URL (default: the kind port mapping)
#   FAILOVER_TIMEOUT   Seconds to wait for each phase (default 180)
#
# Requires kubectl and curl on the caller's PATH.

set -euo pipefail

OPENEMR_HTTPS_URL=${OPENEMR_HTTPS_URL:-https://127.0.0.1:9800/interface/login/login.php}
FAILOVER_TIMEOUT=${FAILOVER_TIMEOUT:-180}
TLS=(--tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key)

log() { echo "[redis-failover] $*"; }
fail() { echo "[redis-failover] FAIL: $*"; exit 1; }

DEFAULT_PW=$(kubectl get secret redis-credentials -o jsonpath='{.data.default-password}' | base64 -d)
ADMIN_PW=$(kubectl get secret redis-credentials -o jsonpath='{.data.admin-password}' | base64 -d)
SENTINELS=$(kubectl get statefulset sentinel -o jsonpath='{.spec.replicas}')

# Short pod name (redis-N) of the master as seen by one Sentinel.
sentinel_master() {
    local out
    out=$(kubectl exec "sentinel-$1" -c sentinel -- env REDISCLI_AUTH="${DEFAULT_PW}" \
        redis-cli -p 26379 "${TLS[@]}" SENTINEL get-master-addr-by-name mymaster 2>/dev/null) || return 1
    out=$(printf '%s\n' "${out}" | head -1)
    printf '%s\n' "${out%%.*}"
}

replication() {
    kubectl exec "$1" -c redis -- env REDISCLI_AUTH="${ADMIN_PW}" \
        redis-cli "${TLS[@]}" --user admin info replication 2>/dev/null | tr -d '\r'
}

OLD_MASTER=$(sentinel_master 0)
[[ "${OLD_MASTER}" =~ ^redis-[0-9]+$ ]] || fail "could not read the master from sentinel-0 (got '${OLD_MASTER}')"
log "current master: ${OLD_MASTER}; deleting it"
kubectl delete pod "${OLD_MASTER}" --wait=false

NEW_MASTER=""
deadline=$(( SECONDS + FAILOVER_TIMEOUT ))
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    m=$(sentinel_master 0 || true)
    if [[ "${m}" =~ ^redis-[0-9]+$ ]] && [[ "${m}" != "${OLD_MASTER}" ]]; then
        NEW_MASTER=${m}
        break
    fi
    sleep 2
done
[[ -n "${NEW_MASTER}" ]] || fail "Sentinel did not fail over from ${OLD_MASTER} within ${FAILOVER_TIMEOUT}s"
log "PASS: Sentinel promoted ${NEW_MASTER}"

kubectl wait --for=condition=Ready "pod/${OLD_MASTER}" --timeout="${FAILOVER_TIMEOUT}s"
deadline=$(( SECONDS + FAILOVER_TIMEOUT ))
rejoined=0
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    info=$(replication "${OLD_MASTER}" || true)
    if grep -q '^role:slave' <<< "${info}" \
        && grep -q "^master_host:${NEW_MASTER}\." <<< "${info}" \
        && grep -q '^master_link_status:up' <<< "${info}"; then
        rejoined=1
        break
    fi
    sleep 2
done
if [[ "${rejoined}" != 1 ]]; then
    printf '%s\n' "${info:-}" | grep -E '^(role|master_host|master_link_status)' || true
    fail "${OLD_MASTER} did not rejoin as a replica of ${NEW_MASTER} with its link up"
fi
log "PASS: ${OLD_MASTER} rejoined as a replica of ${NEW_MASTER}"

# Sentinels learn of the promotion asynchronously, so poll until they agree.
sentinel_state() {
    local i m peers out=""
    for ((i = 0; i < SENTINELS; i++)); do
        m=$(sentinel_master "${i}" || true)
        peers=$(kubectl exec "sentinel-${i}" -c sentinel -- env REDISCLI_AUTH="${DEFAULT_PW}" \
            redis-cli -p 26379 "${TLS[@]}" SENTINEL sentinels mymaster 2>/dev/null | grep -cx 'runid' || true)
        out+="sentinel-${i}: master=${m:-?} peers=${peers:-?}"$'\n'
    done
    printf '%s' "${out}"
}
expected=""
for ((i = 0; i < SENTINELS; i++)); do
    expected+="sentinel-${i}: master=${NEW_MASTER} peers=$((SENTINELS - 1))"$'\n'
done
deadline=$(( SECONDS + FAILOVER_TIMEOUT ))
converged=0
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    state=$(sentinel_state)$'\n'
    if [[ "${state}" = "${expected}" ]]; then
        converged=1
        break
    fi
    sleep 2
done
if [[ "${converged}" != 1 ]]; then
    printf '%s' "${state:-}"
    fail "Sentinels did not all agree on ${NEW_MASTER} with $((SENTINELS - 1)) peers each within ${FAILOVER_TIMEOUT}s (stale peers block elections)"
fi
log "PASS: all ${SENTINELS} Sentinels agree on ${NEW_MASTER} and know exactly $((SENTINELS - 1)) peers"

code=$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' "${OPENEMR_HTTPS_URL}" || true)
[[ "${code}" = "200" ]] || fail "OpenEMR login page returned ${code} after the failover"
log "PASS: OpenEMR answers after the failover"
