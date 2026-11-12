# shellcheck shell=bash
# Data-plane probes shared by rotate-leaf.sh and rotate-ca-test.sh.
#
# Three background probes sample the stack every 1-3s:
#   http   OpenEMR login page over HTTPS (also exercises Redis sessions)
#   mysql  SELECT 1 from an openemr pod to mysql-primary over mTLS
#   nfs    write + read back a file on the NFS-backed sites volume
# Each sample retries up to 3 times (~3s) before it counts as FAIL, which
# absorbs kube-proxy endpoint-sync jitter. The measure is the longest gap
# between consecutive successful samples, which catches both errors and
# hangs (a stalled NFS mount or a slow Sentinel lookup makes a sample hang
# and then succeed, so counting failures alone misses it).
#
# Before sourcing, set PROBE_DIR (log directory, created here) and
# PROBE_TAG (prefix for the NFS probe token), and define log().
#
# Environment:
#   OPENEMR_HTTPS_URL   Login page URL for the HTTP probe
#                       (default https://127.0.0.1:9800/interface/login/login.php,
#                       the kind port mapping in kubernetes/kind-config-*.yaml)
#
# Requires kubectl, jq and curl.

OPENEMR_HTTPS_URL=${OPENEMR_HTTPS_URL:-https://127.0.0.1:9800/interface/login/login.php}
SITES=/var/www/localhost/htdocs/openemr/sites
PROBES=(http mysql nfs)
: "${PROBE_DIR:?set PROBE_DIR before sourcing probe-lib.sh}" "${PROBE_TAG:?set PROBE_TAG before sourcing probe-lib.sh}"
mkdir -p "${PROBE_DIR}"
STOP_FILE="${PROBE_DIR}/stop"

# Ready, non-terminating pods for a label selector.
ready_pods() {
    local json
    json=$(kubectl get pods -l "$1" -o json) || return 1
    jq -r <<< "${json}" '
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name'
}

openemr_pod() {
    local pods
    pods=$(ready_pods name=openemr) || return 1
    printf '%s\n' "${pods%%$'\n'*}"
}

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
    token="${PROBE_TAG}-${RANDOM}${RANDOM}"
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

# Start the probes and wait for 3 OK samples from each. Returns 1 (after
# printing the samples) if the stack never gets there.
start_probes() {
    local p ready
    rm -f "${STOP_FILE}"
    for p in "${PROBES[@]}"; do run_probe "${p}" & done
    log "waiting for probe baseline (3 OK samples each)"
    for _ in $(seq 1 60); do
        ready=1
        for p in "${PROBES[@]}"; do
            [[ "$(grep -c ' OK$' "${PROBE_DIR}/${p}.log" 2>/dev/null || true)" -ge 3 ]] || ready=0
        done
        [[ "${ready}" = 1 ]] && return 0
        sleep 1
    done
    for p in "${PROBES[@]}"; do log "${p} samples:"; cat "${PROBE_DIR}/${p}.log"; done
    return 1
}

stop_probes() {
    touch "${STOP_FILE}"
    wait
}

# Longest gap between consecutive OK samples in a probe log.
longest_gap() {
    awk '$2 == "OK" { if (prev != "") { g = $1 - prev; if (g > max) max = g } prev = $1 }
         END { print max + 0 }' "$1"
}

# check_probes START_TS END_TS MAX_GAP
# Each probe must have sampled from before START_TS until after END_TS,
# have ended on an OK sample, and never gone more than MAX_GAP seconds
# without one. Prints one line per probe; returns 1 on any failure.
check_probes() {
    local start=$1 end=$2 max_gap=$3 status=0 p logf ok bad first last last_result gap
    for p in "${PROBES[@]}"; do
        logf="${PROBE_DIR}/${p}.log"
        ok=$(grep -c ' OK$' "${logf}" || true)
        bad=$(grep -c ' FAIL$' "${logf}" || true)
        first=$(awk 'NR == 1 { print $1 }' "${logf}")
        last=$(awk 'END { print $1 }' "${logf}")
        last_result=$(awk 'END { print $2 }' "${logf}")
        gap=$(longest_gap "${logf}")
        log "probe ${p}: OK=${ok} FAIL=${bad} longest-gap=${gap}s (budget ${max_gap}s)"
        if [[ "${first:-0}" -gt "${start}" ]] || [[ "${last:-0}" -lt "${end}" ]]; then
            log "FAIL: probe ${p} did not cover the window (samples ${first}..${last}, window ${start}..${end})"
            status=1
        fi
        if [[ "${last_result}" = "FAIL" ]]; then
            log "FAIL: probe ${p} had not recovered when the probes stopped"
            status=1
        fi
        if [[ "${gap}" -gt "${max_gap}" ]]; then
            log "FAIL: probe ${p} went ${gap}s without a successful sample (budget ${max_gap}s)"
            awk -v g="${max_gap}" '$2 == "OK" { if (prev != "" && $1 - prev > g) print "  gap " prev " -> " $1; prev = $1 } $2 == "FAIL" { print "  " $0 }' "${logf}"
            status=1
        fi
    done
    return "${status}"
}
