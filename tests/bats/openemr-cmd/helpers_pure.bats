# BATS: pure helper tests for openemr-cmd worktree primitives.
# wt_slug, wt_compose_subdir, wt_validate_env have no I/O dependencies
# beyond a benign OPENEMR_ROOT — exercise them in a subshell with the
# function definitions sourced from the script.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_ROOT=$(oc_mktempdir)
    export TMP_ROOT
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
}

# Run a snippet with the script's function defs sourced. Stdout of the
# snippet is captured by 'run'; OPENEMR_ROOT is forced to a benign tmpdir
# so the script's top-level git-rev-parse fallback never fires.
oc_run_in_funcs() {
    local snippet=$1
    local script_path=$2
    local funcs_end=$3
    local tmp_root=$4
    run env OPENEMR_ROOT="${tmp_root}" bash -c "
        set -euo pipefail
        # eval, not 'source <(...)': process substitution is broken under
        # macOS system bash 3.2, where <() fails to define the functions.
        eval \"\$(head -n ${funcs_end} '${script_path}')\"
        ${snippet}
    "
}

# --- wt_slug -----------------------------------------------------------------

@test "wt_slug: slash becomes dash" {
    oc_run_in_funcs 'wt_slug feature/foo' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "feature-foo"
}

@test "wt_slug: uppercase is lowercased" {
    oc_run_in_funcs 'wt_slug UPPER' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "upper"
}

@test "wt_slug: spaces and special chars are stripped" {
    oc_run_in_funcs "wt_slug 'with spaces!'" "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "withspaces"
}

@test "wt_slug: mixed case + slash + special chars" {
    oc_run_in_funcs "wt_slug 'Feature/My-Thing!'" "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "feature-my-thing"
}

# --- wt_compose_subdir -------------------------------------------------------

@test "wt_compose_subdir: easy" {
    oc_run_in_funcs 'wt_compose_subdir easy' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "docker/development-easy"
}

@test "wt_compose_subdir: easy-light" {
    oc_run_in_funcs 'wt_compose_subdir easy-light' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "docker/development-easy-light"
}

@test "wt_compose_subdir: easy-redis" {
    oc_run_in_funcs 'wt_compose_subdir easy-redis' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "docker/development-easy-redis"
}

# --- wt_validate_env ---------------------------------------------------------

@test "wt_validate_env: accepts easy" {
    oc_run_in_funcs 'wt_validate_env easy && echo ok' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "ok"
}

@test "wt_validate_env: accepts easy-light" {
    oc_run_in_funcs 'wt_validate_env easy-light && echo ok' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "ok"
}

@test "wt_validate_env: accepts easy-redis" {
    oc_run_in_funcs 'wt_validate_env easy-redis && echo ok' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_success
    assert_output "ok"
}

@test "wt_validate_env: rejects bogus env with error message" {
    oc_run_in_funcs 'wt_validate_env bogus 2>&1' "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_failure
    assert_output --partial "Invalid env 'bogus'"
}

@test "wt_validate_env: rejects empty env" {
    oc_run_in_funcs "wt_validate_env '' 2>&1" "$SCRIPT" "${OC_SCRIPT_FUNCS_END}" "$TMP_ROOT"
    assert_failure
}

# --- oc_funcs_source_line is current ----------------------------------------
# If someone restructures openemr-cmd and our OC_SCRIPT_FUNCS_END constant
# drifts (e.g. someone adds another function above the dispatch), this test
# catches it loudly: line OC_SCRIPT_FUNCS_END+1 must be 'USAGE_EXIT_CODE=13'
# or very close to it, signalling the end of the function-defs section.

@test "OC_SCRIPT_FUNCS_END points at end of function defs (USAGE_EXIT_CODE follows)" {
    run sed -n "$((OC_SCRIPT_FUNCS_END+1)),$((OC_SCRIPT_FUNCS_END+3))p" "$SCRIPT"
    assert_success
    assert_output --partial "USAGE_EXIT_CODE="
}
