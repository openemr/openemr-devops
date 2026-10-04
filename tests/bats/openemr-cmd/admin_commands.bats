# BATS: non-worktree admin commands — docker-log (dl), docker-names (dn),
# ensure-version (ev), encoding-collation (ec), maria-shell (ms),
# import-random-patients (irp).
#
# These are NOT devtools passthroughs — each invokes a specific docker
# command or sub-script. Pin the invocation shape via the docker stub.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    CONTAINER=fixed-admin-target
    export STUB_DIR CONTAINER
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_run() {
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d "${CONTAINER}" "$@"
}

# --- docker-log / dl --------------------------------------------------------

@test "dl: invokes 'docker logs <CONTAINER_ID>'" {
    run oc_run dl
    assert_success
    grep -Fq "logs ${CONTAINER}" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'docker logs ${CONTAINER}' invocation"; }
}

@test "dl: 'docker-log' long form is equivalent" {
    run oc_run docker-log
    assert_success
    grep -Fq "logs ${CONTAINER}" "${STUB_DIR}/docker.log" || fail "long form did not invoke 'docker logs'"
}

# --- docker-names / dn ------------------------------------------------------

@test "dn (no arg): lists running + 'other status' containers via 'docker ps' / 'docker ps -a'" {
    run oc_run dn
    assert_success
    # Output structure assertions — the function prints these banners.
    assert_output --partial "Running Docker Names"
    assert_output --partial "Other Docker Status Names"
    # Stub recorded both `ps` (running) and `ps -a` (all) — the function
    # uses both for the two sections.
    grep -Eq "^ps " "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'ps' query"; }
    grep -Eq "^ps -a " "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'ps -a' query"; }
}

@test "dn <name>: 'check single Docker Name' branch fires with the keyword in scope" {
    # check_docker_names with 1 arg goes into the single-name branch.
    run oc_run dn openemr
    assert_success
    assert_output --partial "Check the single Docker Name"
    # 'docker ps -a' is the query in the single-name branch.
    grep -Eq "^ps -a " "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'ps -a' for single-name check"; }
}

# --- import-random-patients / irp / irpc / irpf ---------------------------
# This is the one devtools subcommand where openemr-cmd sets ENV_VAR to a
# real value before calling run_devtools_in_docker (so the -e flag carries
# the OPENEMR_ENABLE_{CCDA,FHIR}_IMPORT gate into the container), AND where
# openemr-cmd flattens the user-facing surface (`--format=ccda|fhir` plus
# `irpc` / `irpf` aliases) down to a positional-arg call into
# `/root/devtools import-random-patients <count> <isDev> <format>` that the
# devtools dispatcher understands.

@test "irp (no format): defaults to ccda — sets OPENEMR_ENABLE_CCDA_IMPORT=1 and 'ccda' as the third positional" {
    run oc_run irp 3 true
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_CCDA_IMPORT=1" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '-e OPENEMR_ENABLE_CCDA_IMPORT=1' in invocation"; }
    grep -Fq "/root/devtools import-random-patients 3 true ccda" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools import-random-patients 3 true ccda' invocation"; }
}

@test "irp: 'import-random-patients' long form is equivalent" {
    run oc_run import-random-patients 2 true
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_CCDA_IMPORT=1" "${STUB_DIR}/docker.log" || fail "long form did not set env var"
    grep -Fq "/root/devtools import-random-patients 2 true ccda" "${STUB_DIR}/docker.log" \
        || fail "long form did not pass 'ccda' as third positional"
}

@test "irp --format=fhir: sets OPENEMR_ENABLE_FHIR_IMPORT=1 and 'fhir' as the third positional" {
    run oc_run irp 2 true --format=fhir
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_FHIR_IMPORT=1" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '-e OPENEMR_ENABLE_FHIR_IMPORT=1' in invocation"; }
    grep -Fq "/root/devtools import-random-patients 2 true fhir" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools import-random-patients 2 true fhir' invocation"; }
    # And ccda env var is NOT also set (the two env vars are mutually exclusive).
    if grep -Fq "OPENEMR_ENABLE_CCDA_IMPORT" "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "fhir format leaked OPENEMR_ENABLE_CCDA_IMPORT into docker exec"
    fi
}

@test "irp --format=ccda: explicit ccda is equivalent to the default" {
    run oc_run irp 1 false --format=ccda
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_CCDA_IMPORT=1" "${STUB_DIR}/docker.log" || fail "explicit --format=ccda did not set CCDA env var"
    grep -Fq "/root/devtools import-random-patients 1 false ccda" "${STUB_DIR}/docker.log" \
        || fail "explicit --format=ccda did not pass 'ccda' as third positional"
}

@test "irp --format=bogus: rejected before docker exec with a usage error" {
    run oc_run irp 1 true --format=bogus
    [[ "${status}" -ne 0 ]] || fail "expected non-zero exit on bad --format; got 0"
    assert_output --partial "unknown --format 'bogus'"
    # Must not have reached run_devtools_in_docker — no docker exec recorded.
    if grep -Fq "/root/devtools import-random-patients" "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "bad --format should abort before the devtools dispatch"
    fi
}

@test "irpf alias: fhir shortcut, both short and long form" {
    run oc_run irpf 4 true
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_FHIR_IMPORT=1" "${STUB_DIR}/docker.log" || fail "irpf did not set FHIR env var"
    grep -Fq "/root/devtools import-random-patients 4 true fhir" "${STUB_DIR}/docker.log" \
        || fail "irpf did not pass 'fhir' as third positional"
    : > "${STUB_DIR}/docker.log"
    run oc_run import-random-patients-fhir 4 true
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_FHIR_IMPORT=1" "${STUB_DIR}/docker.log" || fail "irpf long form did not set FHIR env var"
    grep -Fq "/root/devtools import-random-patients 4 true fhir" "${STUB_DIR}/docker.log" \
        || fail "irpf long form did not pass 'fhir'"
}

@test "irpc alias: ccda shortcut, both short and long form" {
    run oc_run irpc 5 false
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_CCDA_IMPORT=1" "${STUB_DIR}/docker.log" || fail "irpc did not set CCDA env var"
    grep -Fq "/root/devtools import-random-patients 5 false ccda" "${STUB_DIR}/docker.log" \
        || fail "irpc did not pass 'ccda' as third positional"
    : > "${STUB_DIR}/docker.log"
    run oc_run import-random-patients-ccda 5 false
    assert_success
    grep -Fq "exec -e OPENEMR_ENABLE_CCDA_IMPORT=1" "${STUB_DIR}/docker.log" || fail "irpc long form did not set CCDA env var"
    grep -Fq "/root/devtools import-random-patients 5 false ccda" "${STUB_DIR}/docker.log" \
        || fail "irpc long form did not pass 'ccda'"
}

@test "non-irp devtools subcommands do NOT carry OPENEMR_ENABLE_{CCDA,FHIR}_IMPORT" {
    # The env-var set is isolated to irp/irpc/irpf/import-random-patients*;
    # other devtools (e.g. pst) must NOT inherit either gate. Pinning the scoping.
    run oc_run pst
    assert_success
    if grep -Fq "OPENEMR_ENABLE_CCDA_IMPORT" "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "non-irp devtool leaked OPENEMR_ENABLE_CCDA_IMPORT into docker exec"
    fi
    if grep -Fq "OPENEMR_ENABLE_FHIR_IMPORT" "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "non-irp devtool leaked OPENEMR_ENABLE_FHIR_IMPORT into docker exec"
    fi
}

# --- ensure-version / ev --------------------------------------------------
# ev <version> dispatches to `/root/devtools upgrade <version>` via
# run_devtools_in_docker.

@test "ev <version>: dispatches to /root/devtools upgrade <version>" {
    run oc_run ev 5.0.2
    assert_success
    grep -Fq "/root/devtools upgrade 5.0.2" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected '/root/devtools upgrade 5.0.2' invocation"; }
    grep -Fq "${CONTAINER}" "${STUB_DIR}/docker.log" || fail "ev did not target ${CONTAINER}"
}

@test "ev (no args): prints usage hint and exits 22 (no 'unbound variable' crash)" {
    # Regression for a bug where `local FOO=\"$1\"` fired before the arg-count
    # check, crashing under `set -u` with "unbound variable" before the user
    # saw the helpful usage message. Fixed by reordering the check first.
    run oc_run ev
    [[ "${status}" -eq 22 ]] || fail "expected exit 22 (BACKUP_FILE_CODE); got ${status}"
    assert_output --partial "Please provide the OpenEMR version"
    assert_output --partial "ensure-version|ev"
    refute_output --partial "unbound variable"
}

# --- encoding-collation / ec ----------------------------------------------
# ec <encoding> <collation> dispatches to
# `/root/devtools change-encoding-collation <encoding> <collation>`.

@test "ec <encoding> <collation>: dispatches to /root/devtools change-encoding-collation <args>" {
    run oc_run ec utf8mb4 utf8mb4_general_ci
    assert_success
    grep -Fq "/root/devtools change-encoding-collation utf8mb4 utf8mb4_general_ci" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected change-encoding-collation invocation"; }
}

@test "ec (no args): prints usage hint and exits 17 (CHARACTER_SET_COLLATION_CODE)" {
    run oc_run ec
    [[ "${status}" -eq 17 ]] || fail "expected exit 17; got ${status}"
    assert_output --partial "Please provide two parameters"
    assert_output --partial "encoding-collation|ec"
}
