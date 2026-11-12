#!/usr/bin/env bash
# The probe_* and check helpers are predicates: callers use them in
# if/&&/|| on purpose and handle a false result themselves.
# shellcheck disable=SC2310
#
# Force-renew one cert-manager leaf Certificate in the kubernetes/ stack
# and verify the whole reload path end to end:
#
#   1. the Certificate's Secret gets a new tls.crt (cert-manager re-issue)
#   2. every pod of the consuming workload is recreated after the renewal
#      (stakater/reloader rolled it) and is Ready again
#   3. optionally, the running server presents the new certificate
#      (openssl s_client against the live endpoint), and files inside the
#      new pods hold the new certificate
#   4. background data-plane probes (OpenEMR HTTPS, MariaDB over mTLS,
#      NFS-backed sites volume) keep succeeding through the roll. The
#      measure is the longest gap between consecutive successful samples,
#      which catches both errors and hangs (a stalled NFS mount or a slow
#      Sentinel lookup makes a sample hang and then succeed, so counting
#      failures alone misses it). A healthy probe samples every 1-3s.
#
# Usage:
#   rotate-leaf.sh <certificate> <kind/name> [options]
#
# Options:
#   --served-via-openemr HOST:PORT  Endpoint whose presented certificate
#                                   must equal the new one, checked with
#                                   openssl s_client from an openemr pod.
#                                   Repeatable.
#   --served-in-pod PORT            Same check, run inside each pod of the
#                                   workload against localhost:PORT.
#   --pod-file PATH                 File inside each workload pod that
#                                   must hold the new certificate.
#                                   Repeatable.
#   --openemr-file PATH             File inside each openemr pod that must
#                                   hold the new certificate (e.g. the copy
#                                   OpenEMR keeps in its sites volume).
#                                   Repeatable.
#   --max-gap SECONDS               Longest allowed gap between two
#                                   successful samples of any probe
#                                   (default 6, i.e. no visible outage).
#   --timeout SECONDS               Budget for the roll (default 600).
#
# Environment:
#   OPENEMR_HTTPS_URL   Login page URL for the HTTP probe
#                       (default https://127.0.0.1:9800/interface/login/login.php,
#                       the kind port mapping in kubernetes/kind-config-*.yaml)
#   ROTATION_WORKDIR    Directory for probe logs (default: mktemp -d)
#
# Requires kubectl, cmctl, jq, openssl and curl on the caller's PATH.

set -euo pipefail

usage() {
    sed -n '/^# Usage:/,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ $# -ge 2 ]] || usage
CERT=$1
WORKLOAD=$2
shift 2

SERVED_VIA_OPENEMR=()
SERVED_IN_POD=""
POD_FILES=()
OPENEMR_FILES=()
MAX_GAP=6
TIMEOUT=600
while [[ $# -gt 0 ]]; do
    case "$1" in
        --served-via-openemr) SERVED_VIA_OPENEMR+=("$2"); shift 2 ;;
        --served-in-pod) SERVED_IN_POD=$2; shift 2 ;;
        --pod-file) POD_FILES+=("$2"); shift 2 ;;
        --openemr-file) OPENEMR_FILES+=("$2"); shift 2 ;;
        --max-gap) MAX_GAP=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

OPENEMR_HTTPS_URL=${OPENEMR_HTTPS_URL:-https://127.0.0.1:9800/interface/login/login.php}
WORKDIR=${ROTATION_WORKDIR:-$(mktemp -d)}
mkdir -p "${WORKDIR}"
PROBE_DIR="${WORKDIR}/${CERT}"
mkdir -p "${PROBE_DIR}"
STOP_FILE="${PROBE_DIR}/stop"
SITES=/var/www/localhost/htdocs/openemr/sites

log() { echo "[${CERT}] $*"; }
fail() {
    echo "[${CERT}] FAIL: $*"
    touch "${STOP_FILE}"
    wait 2>/dev/null || true
    exit 1
}

fingerprint() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }

secret_fp() {
    kubectl get secret "${SECRET}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
        | base64 -d 2>/dev/null | fingerprint
}

# Ready, non-terminating pods for a label selector.
ready_pods() {
    kubectl get pods -l "$1" -o json | jq -r '
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name'
}

openemr_pod() { ready_pods name=openemr | head -1; }

# ---------------------------------------------------------------------------
# Resolve the Certificate's Secret and the workload's pods.
# ---------------------------------------------------------------------------
SECRET=$(kubectl get certificate "${CERT}" -o jsonpath='{.spec.secretName}')
[[ -n "${SECRET}" ]] || fail "Certificate ${CERT} not found"
SELECTOR=$(kubectl get "${WORKLOAD}" -o json \
    | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
[[ -n "${SELECTOR}" ]] || fail "could not read selector of ${WORKLOAD}"
case "${WORKLOAD}" in
    daemonset/*|ds/*)
        DESIRED=$(kubectl get "${WORKLOAD}" -o jsonpath='{.status.desiredNumberScheduled}') ;;
    *)
        DESIRED=$(kubectl get "${WORKLOAD}" -o jsonpath='{.spec.replicas}') ;;
esac

OLD_FP=$(secret_fp)
[[ -n "${OLD_FP}" ]] || fail "Secret ${SECRET} has no readable tls.crt"
OLD_UIDS=$(kubectl get pods -l "${SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}')
log "secret=${SECRET} workload=${WORKLOAD} selector=${SELECTOR} pods=${DESIRED}"
log "old fingerprint ${OLD_FP}"

# ---------------------------------------------------------------------------
# Background probes. Each sample retries up to 3 times (~3s) before it
# counts as FAIL, which absorbs kube-proxy endpoint-sync jitter.
# ---------------------------------------------------------------------------
probe_http() {
    local code
    code=$(curl -sk -o /dev/null --max-time 5 -w '%{http_code}' "${OPENEMR_HTTPS_URL}") || return 1
    [[ "${code}" = "200" ]]
}
probe_mysql() {
    local pod
    pod=$(openemr_pod) && [[ -n "${pod}" ]] || return 1
    timeout 8s kubectl exec "${pod}" -c openemr -- \
        mariadb -h mysql-primary -u openemr -popenemr \
            --ssl-ca=/root/certs/mysql/server/mysql-ca \
            --ssl-cert=/root/certs/mysql/server/mysql-cert \
            --ssl-key=/root/certs/mysql/server/mysql-key \
            -e "SELECT 1" openemr >/dev/null 2>&1
}
probe_nfs() {
    local pod token got
    pod=$(openemr_pod) && [[ -n "${pod}" ]] || return 1
    token="${CERT}-${RANDOM}${RANDOM}"
    got=$(timeout 8s kubectl exec "${pod}" -c openemr -- sh -c \
        "echo ${token} > ${SITES}/.cert-rotation-probe && cat ${SITES}/.cert-rotation-probe" 2>/dev/null) || return 1
    [[ "${got}" = "${token}" ]]
}

run_probe() {
    local name=$1 logf="${PROBE_DIR}/$1.log" ts ok
    : > "${logf}"
    while [[ ! -f "${STOP_FILE}" ]]; do
        ts=$(date +%s)
        ok=0
        for _ in 1 2 3; do
            if "probe_${name}"; then ok=1; break; fi
            sleep 1
        done
        if [[ "${ok}" = 1 ]]; then echo "${ts} OK" >> "${logf}"; else echo "${ts} FAIL" >> "${logf}"; fi
        sleep 1
    done
}

PROBES=(http mysql nfs)
rm -f "${STOP_FILE}"
for p in "${PROBES[@]}"; do run_probe "${p}" & done

log "waiting for probe baseline (3 OK samples each)"
for _ in $(seq 1 60); do
    ready=1
    for p in "${PROBES[@]}"; do
        [[ "$(grep -c ' OK$' "${PROBE_DIR}/${p}.log" 2>/dev/null || true)" -ge 3 ]] || ready=0
    done
    [[ "${ready}" = 1 ]] && break
    sleep 1
done
[[ "${ready}" = 1 ]] || {
    for p in "${PROBES[@]}"; do log "${p} samples:"; cat "${PROBE_DIR}/${p}.log"; done
    fail "probes never reached a healthy baseline; stack was not healthy before rotation"
}

# ---------------------------------------------------------------------------
# Renew and wait for the new certificate.
# ---------------------------------------------------------------------------
RENEW_TS=$(date +%s)
cmctl renew "${CERT}"
NEW_FP=""
for _ in $(seq 1 60); do
    cur=$(secret_fp)
    if [[ -n "${cur}" ]] && [[ "${cur}" != "${OLD_FP}" ]]; then NEW_FP=${cur}; break; fi
    sleep 2
done
[[ -n "${NEW_FP}" ]] || fail "Secret ${SECRET} did not change within 120s of cmctl renew"
log "PASS: secret re-issued, new fingerprint ${NEW_FP}"

# ---------------------------------------------------------------------------
# Wait until every pod of the workload has been recreated and is Ready.
# ---------------------------------------------------------------------------
ROLLED=0
deadline=$(( SECONDS + TIMEOUT ))
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    replaced=0
    current=$(kubectl get pods -l "${SELECTOR}" -o json | jq -r '
        .items[] | select(.metadata.deletionTimestamp == null) | .metadata.uid')
    total=0
    for uid in ${current}; do
        total=$((total + 1))
        echo "${OLD_UIDS}" | grep -qx "${uid}" || replaced=$((replaced + 1))
    done
    ready=$(ready_pods "${SELECTOR}" | wc -l)
    if [[ "${total}" -eq "${DESIRED}" ]] && [[ "${replaced}" -eq "${DESIRED}" ]] && [[ "${ready}" -eq "${DESIRED}" ]]; then
        ROLLED=1
        break
    fi
    sleep 2
done
if [[ "${ROLLED}" != 1 ]]; then
    kubectl get pods -l "${SELECTOR}" -o wide || true
    fail "${WORKLOAD} was not fully recreated within ${TIMEOUT}s (replaced=${replaced}/${DESIRED} ready=${ready})"
fi
ROLLED_TS=$(date +%s)
log "PASS: all ${DESIRED} pod(s) of ${WORKLOAD} recreated and Ready ($((ROLLED_TS - RENEW_TS))s after renew)"

# Let the probes take a few post-roll samples, then stop them.
sleep 8
touch "${STOP_FILE}"
wait

# ---------------------------------------------------------------------------
# The running processes use the new certificate.
# ---------------------------------------------------------------------------
served_fp_via_openemr() {
    local pod=$1 endpoint=$2
    # The client cert is presented where the server requires one; a server
    # that rejects it still sends its own certificate first.
    kubectl exec "${pod}" -c openemr -- sh -c \
        "openssl s_client -connect ${endpoint} -servername ${endpoint%%:*} </dev/null 2>/dev/null" \
        | fingerprint
}
for endpoint in "${SERVED_VIA_OPENEMR[@]}"; do
    pod=$(openemr_pod)
    got=""
    for _ in 1 2 3 4 5; do
        got=$(served_fp_via_openemr "${pod}" "${endpoint}" || true)
        [[ "${got}" = "${NEW_FP}" ]] && break
        sleep 3
    done
    [[ "${got}" = "${NEW_FP}" ]] || fail "${endpoint} presents ${got:-no certificate}, expected ${NEW_FP}"
    log "PASS: ${endpoint} presents the new certificate"
done

if [[ -n "${SERVED_IN_POD}" ]]; then
    for pod in $(ready_pods "${SELECTOR}"); do
        got=$(kubectl exec "${pod}" -- sh -c \
            "openssl s_client -connect localhost:${SERVED_IN_POD} </dev/null 2>/dev/null" | fingerprint || true)
        [[ "${got}" = "${NEW_FP}" ]] || fail "${pod}:${SERVED_IN_POD} presents ${got:-no certificate}, expected ${NEW_FP}"
        log "PASS: ${pod}:${SERVED_IN_POD} presents the new certificate"
    done
fi

for f in "${POD_FILES[@]}"; do
    for pod in $(ready_pods "${SELECTOR}"); do
        got=$(kubectl exec "${pod}" -- cat "${f}" 2>/dev/null | fingerprint || true)
        [[ "${got}" = "${NEW_FP}" ]] || fail "${pod}:${f} holds ${got:-nothing}, expected ${NEW_FP}"
    done
    log "PASS: ${f} holds the new certificate in every pod"
done

for f in "${OPENEMR_FILES[@]}"; do
    for pod in $(ready_pods name=openemr); do
        got=$(kubectl exec "${pod}" -c openemr -- cat "${f}" 2>/dev/null | fingerprint || true)
        [[ "${got}" = "${NEW_FP}" ]] || fail "openemr ${pod}:${f} holds ${got:-nothing}, expected ${NEW_FP}"
    done
    log "PASS: openemr ${f} holds the new certificate in every pod"
done

# ---------------------------------------------------------------------------
# Data plane through the roll.
# ---------------------------------------------------------------------------
# Longest gap between consecutive OK samples. A probe whose last sample
# is FAIL has not recovered.
longest_gap() {
    awk '$2 == "OK" { if (prev != "") { g = $1 - prev; if (g > max) max = g } prev = $1 }
         END { print max + 0 }' "$1"
}

status=0
for p in "${PROBES[@]}"; do
    logf="${PROBE_DIR}/${p}.log"
    ok=$(grep -c ' OK$' "${logf}" || true)
    bad=$(grep -c ' FAIL$' "${logf}" || true)
    first=$(head -1 "${logf}" | awk '{print $1}')
    last=$(tail -1 "${logf}" | awk '{print $1}')
    gap=$(longest_gap "${logf}")
    log "probe ${p}: OK=${ok} FAIL=${bad} longest-gap=${gap}s (budget ${MAX_GAP}s)"
    # Coverage: the probe ran from before the renewal until after the roll.
    if [[ "${first:-0}" -gt "${RENEW_TS}" ]] || [[ "${last:-0}" -lt "${ROLLED_TS}" ]]; then
        log "FAIL: probe ${p} did not cover the roll (samples ${first}..${last}, renew ${RENEW_TS}, rolled ${ROLLED_TS})"
        status=1
    fi
    if tail -1 "${logf}" | grep -q ' FAIL$'; then
        log "FAIL: probe ${p} had not recovered when the probes stopped"
        status=1
    fi
    if [[ "${gap}" -gt "${MAX_GAP}" ]]; then
        log "FAIL: probe ${p} went ${gap}s without a successful sample (budget ${MAX_GAP}s)"
        awk -v g="${MAX_GAP}" '$2 == "OK" { if (prev != "" && $1 - prev > g) print "  gap " prev " -> " $1; prev = $1 } $2 == "FAIL" { print "  " $0 }' "${logf}"
        status=1
    fi
done
[[ "${status}" = 0 ]] || exit 1
log "PASS: rotation verified (secret re-issued, ${WORKLOAD} reloaded, data plane within ${MAX_GAP}s)"
