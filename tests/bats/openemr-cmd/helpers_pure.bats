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
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${script_path}'
        ${snippet}
    "
}

# --- wt_slug -----------------------------------------------------------------

@test "wt_slug: slash becomes dash" {
    oc_run_in_funcs 'wt_slug feature/foo' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "feature-foo"
}

@test "wt_slug: uppercase is lowercased" {
    oc_run_in_funcs 'wt_slug UPPER' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "upper"
}

@test "wt_slug: spaces and special chars are stripped" {
    oc_run_in_funcs "wt_slug 'with spaces!'" "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "withspaces"
}

@test "wt_slug: mixed case + slash + special chars" {
    oc_run_in_funcs "wt_slug 'Feature/My-Thing!'" "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "feature-my-thing"
}

@test "wt_slug: empty input -> empty output (deterministic, not an error)" {
    oc_run_in_funcs "wt_slug ''" "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output ""
}

@test "wt_slug: non-ASCII chars stripped, surrounding ASCII survives" {
    oc_run_in_funcs "wt_slug 'résumé'" "$SCRIPT" "$TMP_ROOT"
    assert_success
    # `tr -cd 'a-zA-Z0-9_-'` operates byte-by-byte; the 2-byte UTF-8
    # sequences for é (0xc3 0xa9) get dropped, leaving the ASCII letters
    # 'r', 's', 'u', 'm'. Result: "rsum" (NOT empty, NOT "résumé").
    assert_output "rsum"
}

@test "wt_slug: non-ASCII alongside ASCII keeps only the ASCII alnum/_/-" {
    oc_run_in_funcs "wt_slug 'foo-bär-baz'" "$SCRIPT" "$TMP_ROOT"
    assert_success
    # The ä is dropped; foo and baz survive with dashes intact.
    assert_output "foo-br-baz"
}

@test "wt_slug: leading dash is preserved (argv-injection concern documented, not blocked)" {
    # tr -cd '[a-zA-Z0-9_-]' allows '-' anywhere including as the first char.
    # This test pins the current behavior so anyone trying to harden it
    # (e.g., refuse slugs starting with -) updates this test deliberately.
    oc_run_in_funcs "wt_slug '-evil'" "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "-evil"
}

@test "wt_slug: long input is passed through unchanged (no truncation)" {
    local long
    long="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    oc_run_in_funcs "wt_slug '${long}'" "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "${long}"
}

# --- wt_compose_subdir -------------------------------------------------------

@test "wt_compose_subdir: easy" {
    oc_run_in_funcs 'wt_compose_subdir easy' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "docker/development-easy"
}

@test "wt_compose_subdir: easy-light" {
    oc_run_in_funcs 'wt_compose_subdir easy-light' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "docker/development-easy-light"
}

@test "wt_compose_subdir: easy-redis" {
    oc_run_in_funcs 'wt_compose_subdir easy-redis' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "docker/development-easy-redis"
}

# --- wt_validate_env ---------------------------------------------------------

@test "wt_validate_env: accepts easy" {
    oc_run_in_funcs 'wt_validate_env easy && echo ok' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "ok"
}

@test "wt_validate_env: accepts easy-light" {
    oc_run_in_funcs 'wt_validate_env easy-light && echo ok' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "ok"
}

@test "wt_validate_env: accepts easy-redis" {
    oc_run_in_funcs 'wt_validate_env easy-redis && echo ok' "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output "ok"
}

@test "wt_validate_env: rejects bogus env with error message" {
    oc_run_in_funcs 'wt_validate_env bogus 2>&1' "$SCRIPT" "$TMP_ROOT"
    assert_failure
    assert_output --partial "Invalid env 'bogus'"
}

@test "wt_validate_env: rejects empty env" {
    oc_run_in_funcs "wt_validate_env '' 2>&1" "$SCRIPT" "$TMP_ROOT"
    assert_failure
}

# --- source guard for functions-only sourcing -------------------------------
# Replaces the previous OC_SCRIPT_FUNCS_END line-counter drift sentinel.
# The script now has a __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1 guard right
# after the last function def that returns from sourcing before any
# dispatch runs. This test pins both ends of the contract: the guard
# is present in the script AND it actually short-circuits sourcing.

@test "source-funcs-only guard: sourcing with the flag set defines functions but skips dispatch" {
    # Sourcing the script with the flag set should define wt_slug
    # (a function) without printing the version banner / running any
    # other dispatch-side output. Confirm by capturing the return-
    # from-source state: wt_slug works; the script didn't run main
    # dispatch (no USAGE_EXIT_CODE print, no docker probe, etc.).
    run env OPENEMR_ROOT="${TMP_ROOT:-/tmp}" bash -c "
        set -euo pipefail
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '$SCRIPT'
        # Sourcing returned cleanly; wt_slug defined and callable.
        wt_slug 'feature/foo'
    "
    assert_success
    assert_output "feature-foo"
}

@test "source-funcs-only guard: direct execution is unaffected by the flag (script runs normally)" {
    # Without the env var, direct execution must work as before:
    # --version exits with VERSION_EXIT_CODE (14) and prints the
    # canonical "openemr-cmd <ver>" banner.
    #
    # Note: the script's docker-availability check (DOCKER_CODE=16)
    # runs BEFORE --version parsing — macOS GH-hosted runners don't
    # have docker installed, so we stub it via the same helper the
    # other hermetic tests use. The stub satisfies `command -v docker`
    # without invoking real docker.
    local stub_dir
    stub_dir=$(oc_make_docker_stub_dir)
    run env PATH="${stub_dir}:${PATH}" "$SCRIPT" --version
    rm -rf "${stub_dir}"
    [[ "${status}" -eq 14 ]] || fail "expected exit 14 (VERSION_EXIT_CODE), got ${status}"
    [[ "${output}" =~ ^openemr-cmd[[:space:]] ]] || fail "expected version banner, got: ${output}"
}
