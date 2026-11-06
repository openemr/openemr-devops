#!/bin/bash
# Run the OpenEMR install doctor against the compose project in this directory.
# It runs inside the OpenEMR container when that is running, so it checks what actually runs
# (an in-place PHP update, a file edited in the container). When the container won't stay up and
# sites/ is on a volume (as in OpenEMR's compose files), it runs from a throwaway container of the
# same image, sharing its volumes and networks. The idea came from Asher Densmore-Lynn (jesdynf),
# forum t/27118/8.
#
# Safe to pipe from curl: everything is inside main(), which runs only on the last line, so a
# download cut short stops bash with a syntax error instead of running part of the script.
#   curl -fsSL https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-doctor/openemr-doctor-docker.sh | bash
#
# It says which container it picked and how it runs the doctor, on stderr; the report is on stdout.
# Its exit code is the doctor's: 1 when a check fails, else 0 (2 or more: it couldn't run).
# The doctor comes from openemr-doctor.php in this directory if there is one (with scan.php and
# an openemr-doctor-facts/ folder beside it, if they are there), else it downloads the newest
# from the doctor's home (DOCTOR_HOME below), checked against the SHA256SUMS there.
#   --debug (or DEBUG=1): trace every command, and run the doctor with --debug.
#   --skip=NAME,... (or SKIP=...): leave the doctor's checks of those names out (php openemr-doctor.php --list-checks).
#   CONTAINER=name-or-id: the OpenEMR container to check, when the project has more than one.
#   OE=/path: OpenEMR's folder in the container, when the doctor can't find it (it looks for version.php).
#   WEB_USER=name: the web server's user in the container, which the doctor runs as (default apache, as in OpenEMR's image).
#   OPENEMR_DOCTOR_HOME=URL: another home; OPENEMR_DOCTOR_NO_UPDATE_CHECK=1: don't look for a newer copy.
#   curl ... | bash -s -- --debug
#
# License: GPL-3.0-or-later
set -euo pipefail

main() {
    VERSION=0.5.5
    DATE=2026-11-06
    # The doctor's home: where this script downloads the doctor from, and where it looks for a
    # newer copy of itself.
    DOCTOR_HOME=${OPENEMR_DOCTOR_HOME:-https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-doctor}
    DOCTOR_HOME=${DOCTOR_HOME%/}
    DEBUG=${DEBUG:-0}
    SKIP=${SKIP:-}
    OE=${OE:-}
    WEB_USER=${WEB_USER:-apache}
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --debug) DEBUG=1 ;;
            --skip=*) SKIP="${SKIP:+${SKIP},}${arg#*=}" ;;
            *) echo "openemr-doctor-docker.sh: unknown option ${arg} (only --debug and --skip=NAME,...)" >&2; exit 2 ;;
        esac
    done
    if [[ "${DEBUG}" = 1 ]]; then PS4='+ openemr-doctor-docker.sh:${LINENO}: '; set -x; fi
    say() { echo "openemr-doctor-docker.sh ${VERSION}: $*" >&2; }
    # Compose v2 (docker compose), or v1 (docker-compose) on older hosts.
    local compose=(docker-compose)
    if docker compose version >/dev/null 2>&1; then compose=(docker compose); fi
    # NEWER=1 when version $1 is newer than $2, compared as numbers, else NEWER=0.
    newer() {
        local a b i
        IFS=. read -r -a a <<<"$1"; IFS=. read -r -a b <<<"$2"
        NEWER=0
        for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
            if (( 10#${a[i]:-0} > 10#${b[i]:-0} )); then NEWER=1; return 0; fi
            if (( 10#${a[i]:-0} < 10#${b[i]:-0} )); then return 0; fi
        done
    }
    # The version of this script at the home, from its first 8 KB, or nothing (offline, blocked).
    home_version() {
        local head
        head=$(curl -fsSL -m 5 -r 0-8191 "${DOCTOR_HOME}/openemr-doctor-docker.sh" 2>/dev/null) || return 0
        grep -m 1 -E '^    VERSION=[0-9][0-9.]*$' <<<"${head}" | cut -d= -f2 || true
    }
    # Days since this copy's DATE, from the calendar alone (date -d differs between Linux, BusyBox and macOS).
    days_old() {
        local y m d era yoe doy now
        IFS=- read -r y m d <<<"${DATE}"
        y=$((10#${y})); m=$((10#${m})); d=$((10#${d}))
        (( m <= 2 )) && y=$((y - 1))
        era=$((y / 400)); yoe=$((y - era * 400))
        doy=$(( (153 * ((m + 9) % 12) + 2) / 5 + d - 1 ))
        now=$(date -u +%s)
        echo $(( now / 86400 - (era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468) ))
    }
    say "released ${DATE}"
    if [[ -z "${OPENEMR_DOCTOR_NO_UPDATE_CHECK:-}" ]]; then
        local latest age
        latest=$(home_version)
        if [[ -z "${latest}" ]]; then
            age=$(days_old)
            say "couldn't reach ${DOCTOR_HOME} to look for a newer copy; this one is ${age} days old"
        else
            newer "${latest}" "${VERSION}"
            [[ "${NEWER}" = 0 ]] || say "a newer copy, ${latest}, is at ${DOCTOR_HOME}/openemr-doctor-docker.sh; run that one"
        fi
    fi

    local found count
    if [[ -n "${CONTAINER:-}" ]]; then
        CONTAINER=$(docker inspect --format '{{.Id}}' "${CONTAINER}") || { say "no container ${CONTAINER}"; exit 2; }
        say "using the container you named"
    else
        # The OpenEMR containers, found by the image each was started from: the tag stays in its
        # config even after the tag has been pulled again (docker compose ps then shows sha256:...).
        found=$("${compose[@]}" ps -aq | xargs -r docker inspect --format '{{.Id}} {{.Config.Image}} {{.Name}}' | awk '$2 ~ /openemr\/openemr/' || true)
        [[ -n "${found}" ]] || { say "no openemr/openemr container in this compose project (for an image of your own, set CONTAINER=name)"; exit 2; }
        CONTAINER=$(awk 'NR == 1 {print $1}' <<<"${found}")
        count=$(wc -l <<<"${found}")
        if [[ "${count}" -gt 1 ]]; then
            say "this project has ${count} OpenEMR containers: $(awk '{printf "%s%s", sep, substr($3, 2); sep = ", "}' <<<"${found}" || true); checking the first. Set CONTAINER=name to check another."
        fi
    fi
    local name image_tag state image
    name=$(docker inspect --format '{{.Name}}' "${CONTAINER}")
    image_tag=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER}")
    state=$(docker inspect --format '{{.State.Status}}' "${CONTAINER}")
    image=$(docker inspect --format '{{.Image}}' "${CONTAINER}")   # the exact image it runs, so the PHP is the same
    say "container ${name#/}, image ${image_tag}, ${state}"

    # OpenEMR's folder: the first known web root with OpenEMR's version.php, else the first one found
    # within five levels of the usual places, looked for in a throwaway container of the same image
    # with the container's volumes (so it works when the container won't start). OE= overrides.
    if [[ -z "${OE}" ]]; then
        # shellcheck disable=SC2016 # the script runs in the container's sh, which expands it
        local probe='for d in /var/www/localhost/htdocs/openemr /var/www/html/openemr /var/www/openemr /var/www/html /srv/openemr /opt/openemr; do
                if [ -f "$d/version.php" ] && grep -q v_database "$d/version.php"; then echo "$d"; exit 0; fi
            done
            find /var/www /srv /opt /usr/share /home -maxdepth 5 -name version.php 2>/dev/null | while read -r f; do
                if grep -q v_database "$f"; then dirname "$f"; break; fi
            done'
        OE=$(docker run --rm --memory 256m --memory-swap 256m --network none --volumes-from "${CONTAINER}" --entrypoint sh "${image}" -c "${probe}" 2>/dev/null | head -n 1 || true)
        if [[ -n "${OE}" ]]; then
            say "OpenEMR is in ${OE} (its version.php)"
        else
            OE=/var/www/localhost/htdocs/openemr
            say "found no OpenEMR version.php in the image; trying ${OE} (set OE=/path to name the folder)"
        fi
    fi

    WORK=$(mktemp -d)
    CID=""   # a throwaway container not yet started, removed if this script stops first
    trap 'rm -rf "${WORK}"; [[ -z "${CID}" ]] || docker rm -f "${CID}" >/dev/null 2>&1 || true' EXIT
    local want got
    sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
    if [[ -n "${DOCTOR:-}" ]] || [[ -f openemr-doctor.php ]]; then
        DOCTOR=${DOCTOR:-openemr-doctor.php}
        [[ -f "${DOCTOR}" ]] || { say "DOCTOR=${DOCTOR}: no such file"; exit 2; }
        local ddir
        ddir=$(dirname "${DOCTOR}")
        ddir=$(cd "${ddir}" && pwd)
        DOCTOR=${ddir}/${DOCTOR##*/}
        say "doctor: ${DOCTOR}, a copy of your own (not checked against SHA256SUMS)"
    else
        # Time limits, so a connection that stalls stops with the exit 2 below instead of waiting forever.
        curl -fsSL --connect-timeout 15 --max-time 120 -o "${WORK}/openemr-doctor.php" "${DOCTOR_HOME}/openemr-doctor.php" || { say "couldn't download openemr-doctor.php from ${DOCTOR_HOME}"; exit 2; }
        curl -fsSL --connect-timeout 15 --max-time 120 -o "${WORK}/SHA256SUMS" "${DOCTOR_HOME}/SHA256SUMS" || { say "couldn't download SHA256SUMS from ${DOCTOR_HOME}"; exit 2; }
        want=$(awk '$2 == "openemr-doctor.php" || $2 == "*openemr-doctor.php" {print $1}' "${WORK}/SHA256SUMS")
        got=$(sha "${WORK}/openemr-doctor.php")
        if [[ -z "${want}" ]] || [[ "${want}" != "${got}" ]]; then
            say "the downloaded openemr-doctor.php doesn't match ${DOCTOR_HOME}/SHA256SUMS (expected ${want:-no entry}, got ${got}); not running it"
            exit 2
        fi
        chmod 644 "${WORK}/openemr-doctor.php"
        DOCTOR=${WORK}/openemr-doctor.php
        say "doctor: downloaded from ${DOCTOR_HOME}, matches its SHA256SUMS"
    fi
    local dir
    dir=$(dirname "${DOCTOR}")
    # scan.php, which the doctor reads edited files with, beside the doctor: the copy beside a
    # doctor of your own, else the home's, checked the same way. Without it the doctor says so.
    SCAN=""
    if [[ -f "${dir}/scan.php" ]]; then
        SCAN=${dir}/scan.php
        [[ "${DOCTOR}" = "${WORK}/openemr-doctor.php" ]] || say "scan.php: ${SCAN}, beside your doctor (not checked against SHA256SUMS)"
    elif [[ "${DOCTOR}" = "${WORK}/openemr-doctor.php" ]] && curl -fsSL --connect-timeout 15 --max-time 120 -o "${WORK}/scan.php" "${DOCTOR_HOME}/scan.php"; then
        want=$(awk '$2 == "scan.php" || $2 == "*scan.php" {print $1}' "${WORK}/SHA256SUMS")
        got=$(sha "${WORK}/scan.php")
        if [[ -n "${want}" ]] && [[ "${want}" = "${got}" ]]; then
            chmod 644 "${WORK}/scan.php"; SCAN=${WORK}/scan.php
            say "scan.php: downloaded from ${DOCTOR_HOME}, matches its SHA256SUMS"
        else
            rm -f "${WORK}/scan.php"
            say "the downloaded scan.php doesn't match ${DOCTOR_HOME}/SHA256SUMS (expected ${want:-no entry}, got ${got}); the doctor runs without it"
        fi
    fi
    # Release facts in a folder beside the doctor (openemr-doctor-facts/), for a server without
    # internet: the doctor reads them from beside itself.
    FACTS=""
    if [[ -f "${dir}/openemr-doctor-facts/releases.json" ]]; then
        FACTS=${dir}/openemr-doctor-facts
        say "release facts: ${FACTS}, beside the doctor"
    fi
    ARGS=(--openemr="${OE}")
    [[ "${DEBUG}" != 1 ]] || ARGS+=(--debug)
    [[ -z "${SKIP}" ]] || ARGS+=(--skip="${SKIP}")
    # The doctor is told it runs in OpenEMR's image (its advice differs there), and gets the settings
    # meant for it.
    ENVS=(-e OPENEMR_DOCTOR_DOCKER=1)
    # A home on the network: one on this host (file://) means nothing in the container.
    [[ "${OPENEMR_DOCTOR_HOME:-}" != http* ]] || ENVS+=(-e "OPENEMR_DOCTOR_HOME=${OPENEMR_DOCTOR_HOME}")
    [[ -z "${OPENEMR_DOCTOR_NO_UPDATE_CHECK:-}" ]] || ENVS+=(-e OPENEMR_DOCTOR_NO_UPDATE_CHECK=1)

    # The doctor, scan.php and the facts, in one folder the web server's user can read (a copy of
    # your own may be 0600), copied into the container rather than mounted from this host, so a
    # Docker daemon on another host gets them too. The facts sit beside the doctor, where it looks.
    local stage=${WORK}/stage
    mkdir -p "${stage}"
    cp "${DOCTOR}" "${stage}/openemr-doctor.php"
    [[ -z "${SCAN}" ]] || cp "${SCAN}" "${stage}/scan.php"
    [[ -z "${FACTS}" ]] || cp -R "${FACTS}" "${stage}/openemr-doctor-facts"
    chmod -R a+rX "${stage}"

    # sites/ on a volume: a volume at OE/sites, at OE, or at a folder above it.
    local mounts mount on_volume=0 rc=0
    mounts=$(docker inspect --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "${CONTAINER}")
    while IFS= read -r mount; do
        [[ -n "${mount}" ]] || continue
        if [[ "${OE}/sites" = "${mount}" || "${OE}/sites" = "${mount%/}/"* ]]; then on_volume=1; fi
    done <<<"${mounts}"
    if [[ "${state}" = running ]]; then
        # Inside the running container, in a folder of this run's own, removed afterwards.
        say "the container is running: running the doctor in it"
        local tdir
        tdir=$(docker exec "${CONTAINER}" mktemp -d /tmp/openemr-doctor.XXXXXX)
        docker cp "${stage}/." "${CONTAINER}:${tdir}" >/dev/null
        docker exec "${CONTAINER}" chmod -R a+rX "${tdir}"
        docker exec -u "${WEB_USER}" "${ENVS[@]}" "${CONTAINER}" php "${tdir}/openemr-doctor.php" "${ARGS[@]}" || rc=$?
        # Best effort: a container that stopped meanwhile doesn't change the doctor's exit code.
        docker exec "${CONTAINER}" rm -rf "${tdir}" >/dev/null 2>&1 || true
    elif [[ "${on_volume}" = 1 ]]; then
        # A throwaway container of the same image with the container's volumes, on every network
        # it is on (the database may be on any of them). It sees the image and the volumes, not
        # what was changed inside the container itself.
        local nets=() netflag=() network said
        read -r -a nets <<<"$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${CONTAINER}")" || true
        [[ "${#nets[@]}" -eq 0 ]] || netflag=(--network "${nets[0]}")
        said="${nets[*]:-none}"
        said="network${nets[1]:+s} ${said// /, }"
        say "the container isn't running (${state}) and sites/ is on a volume: running the doctor in a throwaway container of the same image, with its volumes, on ${said}"
        say "it sees the image and the volumes, so changes made inside the container itself (a PHP updated in place, an edited file) aren't checked"
        # Capped, so a doctor gone wrong can't take the host's memory.
        CID=$(docker create --rm --memory 1g --memory-swap 1g --volumes-from "${CONTAINER}" ${netflag[@]+"${netflag[@]}"} --user "${WEB_USER}" --entrypoint php \
          "${ENVS[@]}" "${image}" /tools/openemr-doctor.php "${ARGS[@]}")
        docker cp "${stage}/." "${CID}:/tools" >/dev/null
        if [[ "${#nets[@]}" -gt 1 ]]; then
            for network in "${nets[@]:1}"; do docker network connect "${network}" "${CID}"; done
        fi
        docker start -a "${CID}" || rc=$?
        CID=""   # started with --rm: Docker removes it
    else
        say "sites/ isn't on a volume and the container isn't running; start it (docker compose up -d), then run this again"
        exit 2
    fi
    exit "${rc}"
}

main "$@"
