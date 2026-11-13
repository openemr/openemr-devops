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
#      NFS-backed sites volume; see probe-lib.sh) keep succeeding through
#      the roll, measured as the longest gap between successful samples.
#
# Usage:
#   rotate-leaf.sh <certificate> <kind/name> [options]
#
# Options:
#   --served-via-openemr HOST:PORT  Endpoint whose presented certificate
#                                   must equal the new one, checked with
#                                   openssl s_client from an openemr pod.
#                                   Repeatable.
#   --served-client-cert CERT KEY CA
#                                   For --served-via-openemr: present this
#                                   client certificate (paths inside the
#                                   openemr pod), verify the server against
#                                   CA, and require the server to answer a
#                                   PING line over the session, so the check
#                                   fails if the server rejects the client
#                                   certificate.
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
CLIENT_CERT=""
CLIENT_KEY=""
CLIENT_CA=""
POD_FILES=()
OPENEMR_FILES=()
MAX_GAP=6
TIMEOUT=600
while [[ $# -gt 0 ]]; do
    case "$1" in
        --served-via-openemr) SERVED_VIA_OPENEMR+=("$2"); shift 2 ;;
        --served-in-pod) SERVED_IN_POD=$2; shift 2 ;;
        --served-client-cert) CLIENT_CERT=$2; CLIENT_KEY=$3; CLIENT_CA=$4; shift 4 ;;
        --pod-file) POD_FILES+=("$2"); shift 2 ;;
        --openemr-file) OPENEMR_FILES+=("$2"); shift 2 ;;
        --max-gap) MAX_GAP=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

WORKDIR=${ROTATION_WORKDIR:-$(mktemp -d)}
PROBE_DIR="${WORKDIR}/${CERT}"
PROBE_TAG=${CERT}
log() { echo "[${CERT}] $*"; }
# shellcheck source=tests/kubernetes/probe-lib.sh
. "$(dirname "$0")/probe-lib.sh"
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

start_probes || fail "probes never reached a healthy baseline; stack was not healthy before rotation"

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
stop_probes

# ---------------------------------------------------------------------------
# The running processes use the new certificate.
# ---------------------------------------------------------------------------
served_fp_via_openemr() {
    local pod=$1 endpoint=$2 tls_args=""
    if [[ -n "${CLIENT_CERT}" ]]; then
        tls_args="-cert ${CLIENT_CERT} -key ${CLIENT_KEY} -CAfile ${CLIENT_CA}"
    fi
    kubectl exec "${pod}" -c openemr -- sh -c \
        "openssl s_client -connect ${endpoint} -servername ${endpoint%%:*} ${tls_args} </dev/null 2>/dev/null" \
        | fingerprint
}
# With --served-client-cert: a verified handshake with the client cert,
# and the server answers a PING line over it (Redis/Sentinel reply
# -NOAUTH or +PONG). A server that rejects the client cert closes the
# session without a reply.
served_session_answers() {
    local pod=$1 endpoint=$2 reply
    reply=$(kubectl exec "${pod}" -c openemr -- sh -c \
        "printf 'PING\\r\\n' | timeout 5 openssl s_client -connect ${endpoint} -cert ${CLIENT_CERT} -key ${CLIENT_KEY} -CAfile ${CLIENT_CA} -verify_return_error -quiet -ign_eof 2>/dev/null; true") || return 1
    reply=${reply//[$'\r\n']/}
    [[ -n "${reply}" ]]
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
    if [[ -n "${CLIENT_CERT}" ]]; then
        served_session_answers "${pod}" "${endpoint}" \
            || fail "${endpoint} did not answer over a verified session with client cert ${CLIENT_CERT}"
        log "PASS: ${endpoint} presents the new certificate and accepts the client certificate"
    else
        log "PASS: ${endpoint} presents the new certificate"
    fi
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
check_probes "${RENEW_TS}" "${ROLLED_TS}" "${MAX_GAP}" || exit 1
log "PASS: rotation verified (secret re-issued, ${WORKLOAD} reloaded, data plane within ${MAX_GAP}s)"
