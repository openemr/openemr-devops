# BATS: wt_acquire_state_lock / wt_release_state_lock mechanics.
#
# The state lock is a regular FILE atomically created via link(2).
# Concurrent correctness is exercised end-to-end in
# worktree_concurrent.bats; this file pins the lock primitive itself:
#
#   - acquire/release roundtrip leaves no lockfile
#   - a held lock blocks a second acquirer until release OR timeout
#   - the timeout fires with a clear error including manual-cleanup hint
#   - identity-checked release defends against accidental deletion
#
# The lock is steal-free by design. Earlier iterations added auto-steal
# of locks held longer than a stale-threshold for crash recovery, but
# every variant we tried (mkdir+holder, atomic-mv, link(2)+steal-verify)
# eventually surfaced a phantom-acquire race where the steal+restore
# dance let two processes simultaneously believe they held the lock and
# race on .worktrees.json. Without steal, every observer of the lockfile
# sees the same holder PID and no replacements happen behind any
# holder's back. SIGKILL'd holders leave an orphaned lockfile; the next
# acquirer's timeout error documents the manual `rm -f` recovery.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_ROOT=$(oc_mktempdir)
    TMP_STATE="${TMP_ROOT}/.worktrees.json"
    LOCK_FILE="${TMP_STATE}.lock"
    echo '{}' > "${TMP_STATE}"
    export TMP_ROOT TMP_STATE LOCK_FILE
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
    return 0
}

# Run a snippet with the script's function defs sourced. WT_STATE_FILE is
# overridden so the lock helpers operate on our tmp file's sibling lockfile.
run_locked() {
    local snippet=$1
    run env \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WT_STATE_FILE="${TMP_STATE}" \
        WT_STATE_LOCK_STALE_S="${WT_STATE_LOCK_STALE_S:-120}" \
        WT_STATE_LOCK_TIMEOUT_S="${WT_STATE_LOCK_TIMEOUT_S:-300}" \
        bash -c "
            set -uo pipefail
            __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
            # Re-export WT_STATE_FILE so the lock helpers see our tmp file
            # (the script's top-level assignment otherwise overrides our env).
            WT_STATE_FILE='${TMP_STATE}'
            WT_STATE_LOCK_FILE='${LOCK_FILE}'
            ${snippet}
        "
}

# --- acquire/release roundtrip ----------------------------------------------

@test "lock: acquire then release leaves no lockfile on disk" {
    run_locked 'wt_acquire_state_lock; wt_release_state_lock'
    assert_success
    [[ ! -e "${LOCK_FILE}" ]] || fail "lockfile still exists after release"
}

@test "lock: acquire is idempotent for the same shell process (second acquire is a no-op)" {
    # wt_acquire_state_lock checks WT_STATE_LOCK_HELD to short-circuit a
    # second acquire from the same shell. Without that, the second acquire
    # would block waiting on its own lock and hit the timeout.
    run_locked '
        wt_acquire_state_lock
        wt_acquire_state_lock
        wt_release_state_lock
    '
    assert_success
    [[ ! -e "${LOCK_FILE}" ]]
}

# --- another process holds the lock -----------------------------------------

@test "lock: a held lock blocks a second acquirer until release" {
    # Hold the lock externally by manually writing the lockfile. The script
    # acquire should spin (timeout very short for this test) and fail.
    echo $$ > "${LOCK_FILE}"
    WT_STATE_LOCK_TIMEOUT_S=1 WT_STATE_LOCK_STALE_S=9999 \
        run_locked 'wt_acquire_state_lock' 2>&1
    assert_failure
    assert_output --partial "Timed out waiting for state lock"
    # Our externally-held lockfile is still there (the timeout path
    # doesn't unlink it — only release does).
    [[ -f "${LOCK_FILE}" ]]
    rm -f "${LOCK_FILE}"
}

# --- no auto-steal: an ancient lockfile is left alone ----------------------

@test "lock: an externally-held lock is NEVER stolen (no auto-steal)" {
    # Pin the no-steal contract. Even an ancient lockfile with a dead
    # PID is NOT auto-removed; the next acquirer times out with a
    # manual-cleanup hint. This eliminates the phantom-acquire races
    # that earlier steal-enabled iterations of this lock surfaced under
    # contention.
    local dead_pid
    dead_pid=$( ( exec sh -c 'exit 0' ) & echo $! )
    wait "${dead_pid}" 2>/dev/null || true
    echo "${dead_pid}" > "${LOCK_FILE}"
    touch -t 200001010000 "${LOCK_FILE}"   # ancient mtime
    WT_STATE_LOCK_TIMEOUT_S=1 \
        run_locked 'wt_acquire_state_lock' 2>&1
    assert_failure
    assert_output --partial "Timed out waiting for state lock"
    assert_output --partial "remove the lock file manually"
    # Lockfile + PID untouched.
    [[ -f "${LOCK_FILE}" ]] || fail "lockfile was removed despite no-steal contract"
    [[ "$(cat "${LOCK_FILE}")" = "${dead_pid}" ]] || fail "holder PID was overwritten"
    rm -f "${LOCK_FILE}"
}

@test "lock: release is identity-checked — does NOT unlink a different holder's lock" {
    # Simulate the second-order race: process A acquired, was stolen
    # from, and then tries to release. The release MUST notice that
    # the lockfile no longer has its PID and leave it alone (otherwise
    # it would delete the new holder's lock and reopen the race).
    #
    # We fake the state by writing a holder PID different from $$
    # into the lockfile, then setting WT_STATE_LOCK_HELD=1 so release
    # thinks "we" hold it, and asserting release leaves the file intact.
    echo 99999 > "${LOCK_FILE}"   # pretend a different process holds it now
    run_locked 'WT_STATE_LOCK_HELD=1; wt_release_state_lock'
    assert_success
    [[ -f "${LOCK_FILE}" ]] || fail "release deleted a lockfile whose holder PID was NOT ours"
    [[ "$(cat "${LOCK_FILE}")" = "99999" ]] || fail "release overwrote/cleared a different holder's marker"
    rm -f "${LOCK_FILE}"
}

# --- release is safe to call when not held ----------------------------------

@test "lock: release without prior acquire is a no-op (WT_STATE_LOCK_HELD=0)" {
    run_locked 'wt_release_state_lock'
    assert_success
    [[ ! -e "${LOCK_FILE}" ]]
}

@test "lock: acquire fails fast when the lockfile's parent is missing or unwritable" {
    # Point the lock at a non-existent parent. The acquire loop should
    # detect this BEFORE the WT_STATE_LOCK_TIMEOUT_S spin (default 300s)
    # and surface the real error.
    local nowhere="${TMP_ROOT}/does/not/exist/.worktrees.json.lock"
    WT_STATE_LOCK_TIMEOUT_S=60 \
        run env \
            OPENEMR_ROOT="${TMP_ROOT}" \
            WT_STATE_FILE="${TMP_STATE}" \
            WT_STATE_LOCK_TIMEOUT_S=60 \
            bash -c "
                set -uo pipefail
                __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
                WT_STATE_FILE='${TMP_STATE}'
                WT_STATE_LOCK_FILE='${nowhere}'
                wt_acquire_state_lock 2>&1
            "
    assert_failure
    assert_output --partial "State-lock parent dir is missing or unwritable"
    refute_output --partial "Timed out waiting for state lock"
}

@test "lock: concurrent acquirers serialize state mutations (no lost RMW updates)" {
    # Exclusivity invariant: if two acquirers ever simultaneously believe
    # they hold the lock, they'll perform overlapping read-modify-write
    # cycles on shared state and lose updates.
    #
    # Three racers each take the lock, read+increment a counter file
    # (with a sleep inside to widen the RMW window), release. After all
    # racers exit, the counter must equal 3.
    #
    # This test was the canary that exposed an earlier mkdir+holder
    # phantom-acquire race under contention; the steal-free link(2)
    # primitive eliminates it. Pre-link variants failed this test
    # reproducibly under load (3 racers, two writing the same value);
    # post-link it passes deterministically.
    local counter="${TMP_ROOT}/counter"
    echo 0 > "${counter}"
    local out_a="${TMP_ROOT}/racer-a.out" out_b="${TMP_ROOT}/racer-b.out" out_c="${TMP_ROOT}/racer-c.out"

    increment_under_lock() {
        local out=$1
        env \
            OPENEMR_ROOT="${TMP_ROOT}" \
            WT_STATE_FILE="${TMP_STATE}" \
            WT_STATE_LOCK_TIMEOUT_S=10 \
            bash -c "
                set -uo pipefail
                __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
                WT_STATE_FILE='${TMP_STATE}'
                WT_STATE_LOCK_FILE='${LOCK_FILE}'
                if wt_acquire_state_lock 2>/dev/null; then
                    v=\$(cat '${counter}')
                    sleep 0.3
                    v=\$((v + 1))
                    echo \$v > '${counter}'
                    echo \"\$\$ wrote=\$v\"
                    wt_release_state_lock 2>/dev/null
                else
                    echo \"\$\$ acquire-failed\"
                fi
            " > "${out}" 2>&1
    }

    increment_under_lock "${out_a}" &
    increment_under_lock "${out_b}" &
    increment_under_lock "${out_c}" &
    wait

    local final
    final=$(cat "${counter}")
    [[ "${final}" = "3" ]] || {
        echo "--- ${out_a} ---"; cat "${out_a}"
        echo "--- ${out_b} ---"; cat "${out_b}"
        echo "--- ${out_c} ---"; cat "${out_c}"
        fail "lost RMW: expected counter=3, got ${final}"
    }
    # And the lockfile should be cleaned up after all racers exit.
    [[ ! -e "${LOCK_FILE}" ]] || fail "lockfile lingering after race"
}

