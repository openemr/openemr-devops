# BATS: state plumbing — wt_state_set/get/remove and wt_next_offset
# operate purely on WT_STATE_FILE (a JSON file written by jq). Tests use
# a per-test temp state file with WT_STATE_FILE overridden via env.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    TMP_ROOT=$(oc_mktempdir)
    TMP_STATE="${TMP_ROOT}/.worktrees.json"
    echo '{}' > "${TMP_STATE}"
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
}

# Run a snippet with the script's function defs sourced; override
# WT_STATE_FILE so the helpers act on our temp file.
oc_run_state() {
    local snippet=$1
    run env \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WT_STATE_FILE="${TMP_STATE}" \
        bash -c "
            set -euo pipefail
            # eval, not 'source <(...)': process substitution is broken under
            # macOS system bash 3.2, where <() fails to define the functions.
            eval \"\$(head -n ${OC_SCRIPT_FUNCS_END} '${SCRIPT}')\"
            # Re-export WT_STATE_FILE after sourcing: the script's top-level
            # WT_STATE_FILE=... line overrides our env var when sourced.
            WT_STATE_FILE='${TMP_STATE}'
            ${snippet}
        "
}

# --- wt_state_set / wt_state_get round-trip ---------------------------------

@test "wt_state_set then wt_state_get returns fields" {
    oc_run_state '
        wt_state_set "feature/foo" 5 "/tmp/worktree-foo" "easy"
        echo "offset=$(wt_state_get feature/foo offset)"
        echo "dir=$(wt_state_get feature/foo dir)"
        echo "env=$(wt_state_get feature/foo env)"
    '
    assert_success
    assert_output --partial "offset=5"
    assert_output --partial "dir=/tmp/worktree-foo"
    assert_output --partial "env=easy"
}

@test "wt_state_get returns empty for unknown branch" {
    oc_run_state '
        result=$(wt_state_get nonexistent offset)
        echo "[$result]"
    '
    assert_success
    assert_output "[]"
}

# --- wt_state_remove ---------------------------------------------------------

@test "wt_state_remove removes the entry" {
    oc_run_state '
        wt_state_set "feature/foo" 5 "/tmp/foo" "easy"
        wt_state_set "feature/bar" 6 "/tmp/bar" "easy-light"
        wt_state_remove "feature/foo"
        # foo gone, bar remains
        foo_offset=$(wt_state_get feature/foo offset)
        bar_offset=$(wt_state_get feature/bar offset)
        echo "foo=[${foo_offset}]"
        echo "bar=[${bar_offset}]"
    '
    assert_success
    assert_output --partial "foo=[]"
    assert_output --partial "bar=[6]"
}

# --- wt_next_offset ----------------------------------------------------------

@test "wt_next_offset returns 1 on empty state" {
    oc_run_state 'wt_next_offset'
    assert_success
    assert_output "1"
}

@test "wt_next_offset fills gap: used=[1,3] -> 2" {
    oc_run_state '
        wt_state_set "b1" 1 "/tmp/a" "easy"
        wt_state_set "b3" 3 "/tmp/c" "easy"
        wt_next_offset
    '
    assert_success
    assert_output "2"
}

@test "wt_next_offset returns next int: used=[1,2,3] -> 4" {
    oc_run_state '
        wt_state_set "b1" 1 "/tmp/a" "easy"
        wt_state_set "b2" 2 "/tmp/b" "easy"
        wt_state_set "b3" 3 "/tmp/c" "easy"
        wt_next_offset
    '
    assert_success
    assert_output "4"
}

@test "wt_next_offset fills lowest gap when multiple: used=[1,2,4,5] -> 3" {
    oc_run_state '
        wt_state_set "b1" 1 "/tmp/a" "easy"
        wt_state_set "b2" 2 "/tmp/b" "easy"
        wt_state_set "b4" 4 "/tmp/d" "easy"
        wt_state_set "b5" 5 "/tmp/e" "easy"
        wt_next_offset
    '
    assert_success
    assert_output "3"
}
