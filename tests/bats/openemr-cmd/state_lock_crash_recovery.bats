# BATS: behavior under crash scenarios for openemr-cmd worktree.
#
# Two crash classes are exercised:
#
#   (1) Lockfile leak via SIGKILL: an external holder is SIGKILL'd while
#       holding .worktrees.json.lock. EXIT traps don't fire on SIGKILL, so
#       the lockfile lingers. The next acquirer must time out cleanly
#       with the manual-cleanup hint (no auto-steal, per state_lock.bats).
#
#   (2) Orphaned git worktree (no state entry): simulate the narrow
#       window where `git worktree add` registered a worktree on disk
#       but the process died before wt_state_set wrote the entry. A
#       subsequent `worktree add <same-branch>` should surface git's
#       "already checked out" error — not silently overwrite or wedge.
#       `worktree prune` does NOT clean this up (it only walks state
#       entries); manual `git worktree remove` is the recovery path.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    TMP_ROOT="${TMP_PARENT}/primary"
    mkdir -p "${TMP_ROOT}"
    oc_init_repo_with_fixtures "${TMP_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    LOCK_FILE="${STATE_FILE}.lock"
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE LOCK_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

@test "SIGKILL'd holder leaves the lockfile; the next acquirer times out with manual-cleanup hint" {
    # Start a background bash that acquires the lock, then sleeps. SIGKILL
    # it. The EXIT trap won't fire, so the lockfile will linger with the
    # holder PID still inside.
    local holder_log="${TMP_PARENT}/holder.log"
    OPENEMR_ROOT="${TMP_ROOT}" \
    WT_STATE_FILE="${STATE_FILE}" \
    bash -c "
        set -uo pipefail
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
        WT_STATE_FILE='${STATE_FILE}'
        WT_STATE_LOCK_FILE='${LOCK_FILE}'
        wt_acquire_state_lock
        echo holder-acquired
        sleep 30
    " > "${holder_log}" 2>&1 &
    local holder_pid=$!
    # Wait for the holder to have actually acquired the lock.
    local i=0
    while (( i < 100 )); do
        [[ -f "${LOCK_FILE}" ]] && grep -q holder-acquired "${holder_log}" 2>/dev/null && break
        sleep 0.05
        i=$((i + 1))
    done
    [[ -f "${LOCK_FILE}" ]] || fail "holder did not create lockfile in time"

    # Kill -9 the holder. EXIT trap does NOT fire. Lockfile should linger.
    kill -KILL "${holder_pid}" 2>/dev/null || true
    wait "${holder_pid}" 2>/dev/null || true
    [[ -f "${LOCK_FILE}" ]] || fail "lockfile was unexpectedly cleaned after SIGKILL"

    # Now try to acquire the lock with a short timeout. Must fail with the
    # manual-cleanup hint.
    run env \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WT_STATE_FILE="${STATE_FILE}" \
        WT_STATE_LOCK_TIMEOUT_S=1 \
        bash -c "
            set -uo pipefail
            __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
            WT_STATE_FILE='${STATE_FILE}'
            WT_STATE_LOCK_FILE='${LOCK_FILE}'
            wt_acquire_state_lock 2>&1
        "
    assert_failure
    assert_output --partial "Timed out waiting for state lock"
    assert_output --partial "remove the lock file manually"
    # Lockfile still present (we never stole it).
    [[ -f "${LOCK_FILE}" ]] || fail "lockfile was removed despite no-steal contract"
}

@test "after manual cleanup of an orphaned lockfile, the next operation succeeds" {
    # The documented recovery for a SIGKILL'd holder. Write a fake
    # lockfile, then `rm -f` it, then perform a real state op. Tests
    # that the recovery instructions actually work end-to-end.
    echo 99999 > "${LOCK_FILE}"
    rm -f "${LOCK_FILE}"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=10 \
        "${SCRIPT}" worktree add recovered-branch -b --env easy
    assert_success
    assert_output --partial "Worktree 'recovered-branch' ready"
    [[ "$(jq -r 'has("recovered-branch")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry not written after recovery"
    [[ ! -e "${LOCK_FILE}" ]] || fail "lockfile still present after successful op"
}

@test "orphaned git worktree (no state entry) leads to git already-checked-out error on second add" {
    # Simulate the narrow crash window: process registered a git worktree
    # via `git worktree add ... -b orphaned-branch <dir>` but died before
    # wt_state_set wrote the entry.
    local orphan_dir="${TMP_PARENT}/openemr-wt-orphaned-branch"
    git -C "${TMP_ROOT}" worktree add --quiet --no-track -b orphaned-branch "${orphan_dir}" master >/dev/null

    # State has no entry for this branch.
    [[ ! -f "${STATE_FILE}" ]] || [[ "$(jq -r 'has("orphaned-branch")' "${STATE_FILE}")" = "false" ]] \
        || fail "fixture state should NOT contain orphaned-branch"

    # Now invoke worktree add for the same branch. Should fail with git's
    # message — NOT silently succeed.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=10 \
        "${SCRIPT}" worktree add orphaned-branch -b --env easy
    assert_failure
    # `git worktree add` will refuse because the branch already exists.
    # Tolerate either git's "already exists" or its "already checked out" phrasing.
    if ! ( echo "${output}" | grep -Eq "already (exists|checked out|used by worktree)" ); then
        echo "${output}"
        fail "expected git's already-exists/checked-out error"
    fi
    # State must not have an entry — we didn't get to wt_state_set.
    if [[ -f "${STATE_FILE}" ]]; then
        [[ "$(jq -r 'has("orphaned-branch")' "${STATE_FILE}")" = "false" ]] \
            || fail "state entry was written despite git failure"
    fi
    # Lockfile cleaned up (the trap fired on wt_die's exit).
    [[ ! -e "${LOCK_FILE}" ]] || fail "lockfile lingering after failed add"
}

@test "orphaned git worktree: manual recovery then worktree add succeeds" {
    # End-to-end recovery: confirm the documented manual path works.
    local orphan_dir="${TMP_PARENT}/openemr-wt-recoverable"
    git -C "${TMP_ROOT}" worktree add --quiet --no-track -b recoverable "${orphan_dir}" master >/dev/null

    # Manual recovery step (would be documented for the user).
    git -C "${TMP_ROOT}" worktree remove --force "${orphan_dir}"
    git -C "${TMP_ROOT}" branch -D recoverable

    # Now the add should succeed cleanly.
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        WT_STATE_LOCK_TIMEOUT_S=10 \
        "${SCRIPT}" worktree add recoverable -b --env easy
    assert_success
    [[ "$(jq -r 'has("recoverable")' "${STATE_FILE}")" = "true" ]] \
        || fail "state entry not present after recovery"
}
