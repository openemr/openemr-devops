# BATS: 'openemr-cmd worktree remove <branch>' graceful path when the
# worktree dir is already gone from disk.
#
# Contract (added in PR #766): when the on-disk dir is missing, skip the
# 'Continue? [y/N]' prompt and the destructive teardown steps; just clean
# up the state entry and emit a hint about leftover docker resources.
# Exit 0.
#
# Rationale: dirs frequently disappear out-of-band (manual rm -rf, IDE
# clean, etc.); failing fast or prompting for confirmation in that case
# blocks the user from clearing state without giving them a useful option.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    TMP_WT_PARENT=$(oc_mktempdir)
    TMP_OPENEMR_ROOT="${TMP_WT_PARENT}/repo"
    mkdir -p "${TMP_OPENEMR_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_OPENEMR_ROOT}/.worktrees.json"

    oc_init_repo "${TMP_OPENEMR_ROOT}"
}

teardown() {
    [[ -n "${TMP_WT_PARENT:-}" ]] && rm -rf "${TMP_WT_PARENT}"
    [[ -n "${STUB_DIR:-}" ]]      && rm -rf "${STUB_DIR}"
}

@test "remove <branch> when dir is gone: no prompt, exit 0, prints docker-cleanup hint, state entry removed" {
    # State entry whose dir is intentionally not created on disk.
    cat > "${STATE_FILE}" <<JSON
{
  "feature/gone": {"offset": 1, "dir": "${TMP_WT_PARENT}/does-not-exist", "env": "easy"}
}
JSON

    # No stdin redirection: the graceful path skips `read -rp` entirely.
    # If it ever regressed and prompted again, this run would block
    # forever (BATS would kill it on timeout). The fast pass IS the
    # "no prompt" assertion.
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_OPENEMR_ROOT}" \
        WORKTREE_PARENT="${TMP_WT_PARENT}" \
        "$SCRIPT" worktree remove feature/gone
    assert_success

    # The graceful-path 'wt_info' messages must be present.
    assert_output --partial "Worktree dir was already gone"
    # Docker-cleanup hint uses the slugified branch name. wt_slug
    # turns 'feature/gone' into 'feature-gone'.
    assert_output --partial "docker compose -p openemr-feature-gone down -v"
    # And we must NOT have seen the destructive-path prompt.
    refute_output --partial "Continue? [y/N]"

    # State entry actually removed.
    run jq -r 'has("feature/gone")' "${STATE_FILE}"
    assert_success
    assert_output "false"
}

# --- destructive happy path (default + --keep-volumes) ----------------------
# The remove command's non-graceful path (dir-exists) does compose down with
# or without --volumes, then `git worktree remove --force`, then
# wt_state_remove. The fixture builds out a real registered worktree (via
# oc_init_repo_with_fixtures + the add subcommand) so the destructive path
# can run end-to-end against the stubbed docker.

setup_full_worktree() {
    # Replace the bare init from `setup()` with the fixture'd init so add
    # has the docker/development-<env>/ dirs to work with.
    rm -rf "${TMP_OPENEMR_ROOT}"
    mkdir -p "${TMP_OPENEMR_ROOT}"
    oc_init_repo_with_fixtures "${TMP_OPENEMR_ROOT}"
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_OPENEMR_ROOT}" \
        WORKTREE_PARENT="${TMP_WT_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_OPENEMR_ROOT}" \
        "$SCRIPT" worktree add "$@"
    assert_success
    : > "${STUB_DIR}/docker.log"
}

@test "remove <branch> (default): confirms, runs 'compose ... down --volumes', removes worktree + state" {
    setup_full_worktree feature-rm -b
    # `remove` prompts; pipe 'y' to confirm.
    run bash -c "echo y | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        '${SCRIPT}' worktree remove feature-rm"
    assert_success
    # Compose down called with --volumes
    grep -F -e "-p openemr-feature-rm" "${STUB_DIR}/docker.log" \
        | grep -F -e "down --volumes" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'down --volumes' invocation"; }
    # Worktree dir gone
    [[ ! -d "${TMP_WT_PARENT}/openemr-wt-feature-rm" ]] \
        || fail "worktree dir should be removed"
    # State entry gone
    run jq -r 'has("feature-rm")' "${STATE_FILE}"
    assert_output "false"
}

@test "remove <branch> --keep-volumes: runs 'compose ... down' WITHOUT --volumes" {
    setup_full_worktree feature-rm-keep -b
    run bash -c "echo y | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        '${SCRIPT}' worktree remove feature-rm-keep --keep-volumes"
    assert_success
    # The compose invocation for this remove is 'down' (no --volumes).
    local line
    line=$(grep -F -e "-p openemr-feature-rm-keep" "${STUB_DIR}/docker.log" | head -1)
    [[ -n "${line}" ]] || { cat "${STUB_DIR}/docker.log"; fail "expected compose invocation not found"; }
    [[ "${line}" == *" down" ]] || fail "expected trailing 'down'; saw: ${line}"
    [[ "${line}" != *"--volumes"* ]] || fail "--keep-volumes should suppress --volumes; saw: ${line}"
    # State entry still gone after a successful remove (state cleanup is
    # independent of the keep-volumes flag).
    run jq -r 'has("feature-rm-keep")' "${STATE_FILE}"
    assert_output "false"
}

# --- A5: permission probe ---------------------------------------------------
# Before any destructive op, cmd_worktree_remove walks the dir for unwritable
# subdirectories (the symptom of container-uid files in the bind mount). If
# any are found it bails with a chown hint, ensuring nothing has been
# destroyed yet — state entry, dir contents, lockfile all preserved for
# retry.

@test "remove: probe refuses early when a subdir is unwritable (container-uid simulation)" {
    # Root ignores DAC permissions — chmod 0500 still leaves the dir
    # writable for uid 0, so the probe sees nothing wrong and the test's
    # premise breaks. Skip when running as root (e.g., some CI images or
    # rootless container test envs).
    [[ "$(id -u)" -ne 0 ]] || skip "test relies on DAC permissions; uid 0 bypasses them"
    setup_full_worktree feature-rm-probe -b
    # Mimic the container-uid case: a subdir inside the worktree we can no
    # longer write to. chmod 0500 means r-x for owner — we can read+enter,
    # but cannot unlink children. rm -rf would fail with EACCES here.
    local sub="${TMP_WT_PARENT}/openemr-wt-feature-rm-probe/uneditable-by-host"
    mkdir -p "${sub}"
    : > "${sub}/sentinel"
    chmod 0500 "${sub}"

    # Reset the docker.log so we can assert NO compose down was issued.
    : > "${STUB_DIR}/docker.log"

    run bash -c "echo y | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        '${SCRIPT}' worktree remove feature-rm-probe"

    # Restore perms so teardown's rm -rf can clean up.
    chmod 0700 "${sub}" 2>/dev/null || true

    assert_failure
    # Clear, actionable error mentioning the unwritable dir + the
    # sudo-chown recovery option (the only option now — the earlier
    # in-container auto-chown shim was removed once HOST_UID adoption
    # made it obsolete; for users on pre-HOST_UID images, sudo chown
    # is the manual workaround).
    assert_output --partial "is not writable by you"
    assert_output --partial "${sub}"
    assert_output --partial "sudo chown -R"
    # Nothing destructive ran: no compose down, no rm of dir, state intact.
    if grep -F -e " down " "${STUB_DIR}/docker.log" >/dev/null 2>&1; then
        cat "${STUB_DIR}/docker.log"
        fail "compose down ran despite the permission probe failing"
    fi
    [[ -d "${TMP_WT_PARENT}/openemr-wt-feature-rm-probe" ]] \
        || fail "worktree dir was removed despite the permission probe failing"
    [[ -f "${sub}/sentinel" ]] || fail "sentinel inside unwritable subdir was deleted"
    run jq -r 'has("feature-rm-probe")' "${STATE_FILE}"
    assert_output "true"
    # Lockfile released by the EXIT trap on wt_die.
    [[ ! -e "${STATE_FILE}.lock" ]] \
        || fail "state lockfile lingering after probe-refused remove"
}

@test "remove: probe is a no-op when all dirs are writable (happy path still works)" {
    # The probe walks the tree but finds nothing unwritable, so it should
    # not interfere with a normal remove. setup_full_worktree creates a
    # worktree with default-perm dirs, so this is essentially the same as
    # the default-remove test above — kept as an explicit regression guard
    # in case the probe ever starts false-positiving.
    setup_full_worktree feature-rm-probe-noop -b
    run bash -c "echo y | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        '${SCRIPT}' worktree remove feature-rm-probe-noop"
    assert_success
    refute_output --partial "is not writable by you"
    run jq -r 'has("feature-rm-probe-noop")' "${STATE_FILE}"
    assert_output "false"
}

# --- Confirmation prompt + no auto-chown shim ----------------------------
# The earlier #833 in-container auto-chown shim was removed once HOST_UID
# adoption (#840 + openemr/openemr#12642 + #12647) made the shim's
# host-uid → host-uid chown a permanent no-op. The probe + the pre-create
# + the probe-loosening (#838) are the safety net for any drift cases.
# These tests pin the user-prompt behavior + the "no chown shim" contract.

@test "remove: aborted at the prompt leaves NO side effects (no destruction)" {
    # If the user aborts at the y/N confirmation, NOTHING runs after
    # the prompt — no compose down, no git worktree remove, no state
    # mutation. Pin the contract: aborted remove leaves the worktree
    # exactly as it was.
    setup_full_worktree feature-rm-abort -b
    local wt_dir
    wt_dir=$(jq -r '.["feature-rm-abort"].dir' "${STATE_FILE}")
    : > "${STUB_DIR}/docker.log"
    run bash -c "echo n | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        '${SCRIPT}' worktree remove feature-rm-abort"
    assert_success
    assert_output --partial "Aborted."
    # No `docker exec` invocation of any kind (proves the script
    # didn't sneak any side effects past the prompt; also serves as
    # a regression guard against any future shim re-introduction).
    # Match the `exec` subcommand broadly (any flags, any user) — the
    # earlier `exec -u root` check was too narrow and would miss a
    # `docker exec --tty <id> chown ...` variant.
    if grep -qE '^(exec|exec[[:space:]])' "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "remove fired a docker exec before the prompt; aborted remove left side effects"
    fi
    # And nothing destructive: dir still on disk, state entry still present.
    [[ -d "${wt_dir}" ]] || fail "worktree dir gone after aborted remove"
    run jq -r 'has("feature-rm-abort")' "${STATE_FILE}"
    assert_output "true"
}

@test "remove: never invokes docker exec for chown (shim removed)" {
    # Regression guard: the #833 in-container auto-chown shim was
    # removed once HOST_UID adoption made it a permanent no-op
    # (chowning host-uid → host-uid). If anyone ever re-introduces
    # that shim, this test fires loudly. DOCKER_PS_OUTPUT is set so
    # the script COULD find a target container — proving the absence
    # of the docker exec is a deliberate choice, not just "no container
    # was available".
    setup_full_worktree feature-rm-no-shim -b
    local wt_dir
    wt_dir=$(jq -r '.["feature-rm-no-shim"].dir' "${STATE_FILE}")
    : > "${STUB_DIR}/docker.log"
    run bash -c "echo y | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        DOCKER_PS_OUTPUT='fake-openemr-container-id' \
        '${SCRIPT}' worktree remove feature-rm-no-shim"
    assert_success
    refute_output --partial "Auto-chowning bind mount via container"
    # No `docker exec` of any kind (chown or otherwise) should have
    # been issued by the remove flow itself. compose down is invoked
    # via `docker compose` (compose subcommand), not `docker exec`,
    # so matching the `exec` subcommand broadly remains a specific
    # shim guard against any future `docker exec` re-introduction
    # regardless of flag shape.
    if grep -qE '^(exec|exec[[:space:]])' "${STUB_DIR}/docker.log"; then
        cat "${STUB_DIR}/docker.log"
        fail "remove invoked docker exec for chown — shim re-introduced?"
    fi
    # Remove still succeeds end-to-end.
    run jq -r 'has("feature-rm-no-shim")' "${STATE_FILE}"
    assert_output "false"
    [[ ! -e "${wt_dir}" ]] || fail "worktree directory still exists: ${wt_dir}"
}

# --- existing tamper guard ------------------------------------------------

@test "remove: when state dir is outside WORKTREE_PARENT, validation refuses early (no destructive action)" {
    # Tamper with the state file so dir points OUTSIDE WORKTREE_PARENT.
    # wt_validate_dir (invoked inside wt_compose_cmd before any docker or
    # git mutation) catches this case before `git worktree remove --force`
    # or the rm-rf fallback can run. Asserting the SAFETY contract — no
    # destructive action — even though wt_compose_cmd suppresses stderr,
    # which is why we don't check for a specific error string here.
    local outside="${TMP_WT_PARENT}/../outside-parent-${RANDOM}"
    mkdir -p "${outside}"
    : > "${outside}/sentinel"
    cat > "${STATE_FILE}" <<JSON
{
  "feature/tamper": {"offset": 1, "dir": "${outside}", "env": "easy"}
}
JSON
    run bash -c "echo y | env \
        PATH='${STUB_DIR}:${PATH}' \
        OPENEMR_ROOT='${TMP_OPENEMR_ROOT}' \
        WORKTREE_PARENT='${TMP_WT_PARENT}' \
        '${SCRIPT}' worktree remove feature/tamper"
    assert_failure
    # Critical safety invariants — nothing destructive happened:
    [[ -d "${outside}" ]] || fail "out-of-parent target was deleted — guard failed"
    [[ -f "${outside}/sentinel" ]] || fail "out-of-parent target's contents were deleted"
    # State entry NOT removed (wt_state_remove never ran).
    run jq -r 'has("feature/tamper")' "${STATE_FILE}"
    assert_output "true"
    rm -rf "${outside}"
}
