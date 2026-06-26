# BATS: wt_copy_base_env — copy primary .env into a new worktree.
#
# Contract:
#   - No-op (rc 0) when source .env is missing.
#   - No-op when source .env is a symlink (refuses to follow).
#   - Copies and preserves mode when source is a regular file and dest is absent.
#   - No-op when dest .env already exists as a regular file (no clobber).
#   - No-op when dest .env exists as a broken symlink (would otherwise follow
#     through cp and write at the link target, possibly outside the worktree).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_ROOT=$(oc_mktempdir)
    PRIMARY="${TMP_ROOT}/primary"
    DEST="${TMP_ROOT}/dest"
    mkdir -p "${PRIMARY}" "${DEST}"
    export TMP_ROOT PRIMARY DEST
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
}

# Run a snippet with the script's function defs sourced (mirrors the pattern
# in helpers_pure.bats — kept here to avoid cross-file coupling).
oc_run_in_funcs() {
    local snippet=$1
    local script_path=$2
    local tmp_root=$3
    run env OPENEMR_ROOT="${tmp_root}" bash -c "
        set -euo pipefail
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${script_path}'
        ${snippet}
    "
}

# Portable file mode read — GNU stat uses -c, BSD/macOS stat uses -f.
# The format string drops to the last 4 octal digits so e.g. 100600 -> 0600.
oc_file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

@test "wt_copy_base_env: no-op when source .env is missing" {
    oc_run_in_funcs "wt_copy_base_env '${PRIMARY}' '${DEST}'" \
        "$SCRIPT" "$TMP_ROOT"
    assert_success
    [[ ! -e "${DEST}/.env" ]]
}

@test "wt_copy_base_env: no-op when source .env is a symlink" {
    # Symlink target content should NEVER end up at DEST/.env.
    echo "EVIL=1" > "${TMP_ROOT}/outside"
    ln -s "${TMP_ROOT}/outside" "${PRIMARY}/.env"
    oc_run_in_funcs "wt_copy_base_env '${PRIMARY}' '${DEST}'" \
        "$SCRIPT" "$TMP_ROOT"
    assert_success
    [[ ! -e "${DEST}/.env" ]]
}

@test "wt_copy_base_env: copies content and preserves 0600 mode" {
    printf 'OPENEMR__ENVIRONMENT=dev\n' > "${PRIMARY}/.env"
    chmod 600 "${PRIMARY}/.env"
    oc_run_in_funcs "wt_copy_base_env '${PRIMARY}' '${DEST}'" \
        "$SCRIPT" "$TMP_ROOT"
    assert_success
    assert_output --partial "Copied base .env"
    [[ -f "${DEST}/.env" ]]
    [[ ! -L "${DEST}/.env" ]]
    diff "${PRIMARY}/.env" "${DEST}/.env"
    [[ "$(oc_file_mode "${DEST}/.env")" == "600" ]]
}

@test "wt_copy_base_env: does not clobber an existing regular dest" {
    printf 'NEW=1\n' > "${PRIMARY}/.env"
    printf 'OLD=1\n' > "${DEST}/.env"
    oc_run_in_funcs "wt_copy_base_env '${PRIMARY}' '${DEST}'" \
        "$SCRIPT" "$TMP_ROOT"
    assert_success
    refute_output --partial "Copied base .env"
    grep -q "^OLD=1$" "${DEST}/.env"
}

@test "wt_copy_base_env: refuses dest that is a broken symlink (no write-through)" {
    # The whole point: a broken symlink fails -e, so a naive check would
    # let cp follow the symlink and write at its target. Verify we refuse
    # AND that the target stays untouched.
    printf 'NEW=1\n' > "${PRIMARY}/.env"
    ln -s "${TMP_ROOT}/should-not-exist" "${DEST}/.env"
    oc_run_in_funcs "wt_copy_base_env '${PRIMARY}' '${DEST}'" \
        "$SCRIPT" "$TMP_ROOT"
    assert_success
    refute_output --partial "Copied base .env"
    [[ -L "${DEST}/.env" ]]
    [[ ! -e "${TMP_ROOT}/should-not-exist" ]]
}
