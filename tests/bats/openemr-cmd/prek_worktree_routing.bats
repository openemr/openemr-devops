# BATS: `openemr-cmd prek` — cwd-aware worktree container routing.
#
# When git commits fire from inside a managed worktree, the pre-commit
# git hook invokes `openemr-cmd prek run`, and prek must dispatch to
# THAT worktree's container — never to some other worktree's container
# just because it happens to be running. Silent misrouting was the bug:
# the pre-commit run would exec inside the wrong container, which reads
# a different checkout via its own bind mount and reports "no files to
# check" for every hook (its git index doesn't match this worktree's
# staged files). The commit then completed with zero validation.
#
# Fix: `wt_resolve_container_from_cwd` now emits `<branch><TAB><container>`
# on stdout, letting the prek dispatch distinguish the three states via
# the tab-separated pair:
#
#   `<TAB>`               cwd is NOT a worktree (primary repo or
#                         arbitrary dir). Fallback to CONTAINER_ID is
#                         correct.
#   `<branch><TAB>`       cwd IS a worktree but its stack is down.
#                         Refuse to fall back; error with the worktree
#                         name so the operator knows exactly which
#                         stack to bring up.
#   `<branch><TAB><id>`   Happy path — dispatch to `<id>`.
#
# Complements prek_dispatch.bats (which pins the outer docker exec
# shape via -d bypass, sidestepping cwd routing entirely).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

# Build a docker stub that:
#   - 'compose' (plugin probe): exit 0
#   - Any label-filter ps: emits the payload from LABEL_PS_OUTPUT env
#     (default empty) so tests can simulate "worktree stack down"
#     (empty) vs "worktree stack up" (container ID).
#   - Everything else: no output, exit 0.
# Records every invocation to docker.log.
oc_make_docker_label_ps_stub() {
    local d log
    d=$(oc_mktempdir)
    log="${d}/docker.log"
    : > "${log}"
    cat > "${d}/docker" <<STUB
#!/bin/sh
echo "\$@" >> "${log}"
case " \$* " in
    *' compose '*|*'compose ')
        exit 0
        ;;
    *' ps '*)
        # Emit LABEL_PS_OUTPUT verbatim for any ps call. Tests set it
        # empty to simulate "no matching container" (stack down), or
        # to a fake container ID to simulate "stack up".
        [ -n "\${LABEL_PS_OUTPUT-}" ] && printf '%s\n' "\${LABEL_PS_OUTPUT}"
        ;;
esac
exit 0
STUB
    chmod +x "${d}/docker"
    echo "${d}"
}

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_ROOT=$(oc_mktempdir)
    STUB_DIR=$(oc_make_docker_label_ps_stub)
    export TMP_ROOT STUB_DIR
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# --- wt_resolve_container_from_cwd: tab-separated output contract ---------

@test "wt_resolve_container_from_cwd: emits '<branch><TAB>' when cwd matches a worktree but the stack is down" {
    # Stand up a git repo + a fake managed worktree registered in
    # .worktrees.json. cd into the worktree dir; docker stub returns
    # empty for the label-filter ps (stack is down). Expected output
    # shape: "my-branch\t" — branch present, container empty. The
    # caller uses this to distinguish "not in a worktree" (both empty)
    # from "in this worktree but stack down" (branch set, container
    # empty) and fail loud instead of silently falling back.
    oc_init_repo "${TMP_ROOT}"
    local wt_dir="${TMP_ROOT}/openemr-wt-my-branch"
    mkdir -p "${wt_dir}"
    oc_init_repo "${wt_dir}"
    cat > "${TMP_ROOT}/.worktrees.json" <<JSON
{"my-branch": {"dir": "${wt_dir}"}}
JSON
    run env OPENEMR_ROOT="${TMP_ROOT}" WT_STATE_FILE="${TMP_ROOT}/.worktrees.json" \
        PATH="${STUB_DIR}:${PATH}" bash -c "
        set -euo pipefail
        cd '${wt_dir}'
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
        IFS=\$'\t' read -r branch container < <(wt_resolve_container_from_cwd)
        printf 'BRANCH=[%s]\nCONTAINER=[%s]\n' \"\${branch}\" \"\${container}\"
    "
    assert_success
    assert_output --partial "BRANCH=[my-branch]"
    assert_output --partial "CONTAINER=[]"
}

@test "wt_resolve_container_from_cwd: emits '<TAB>' when cwd is not in the state file" {
    # cwd is a git repo but NOT registered in .worktrees.json.
    # The function should output an empty branch AND empty container
    # (single tab char). Exercises the "walked all entries, none
    # matched" branch of the resolution loop.
    oc_init_repo "${TMP_ROOT}"
    # State file exists but contains a DIFFERENT worktree.
    cat > "${TMP_ROOT}/.worktrees.json" <<JSON
{"other-branch": {"dir": "/nonexistent/other/worktree"}}
JSON
    run env OPENEMR_ROOT="${TMP_ROOT}" WT_STATE_FILE="${TMP_ROOT}/.worktrees.json" \
        PATH="${STUB_DIR}:${PATH}" bash -c "
        set -euo pipefail
        cd '${TMP_ROOT}'
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
        IFS=\$'\t' read -r branch container < <(wt_resolve_container_from_cwd)
        printf 'BRANCH=[%s]\nCONTAINER=[%s]\n' \"\${branch}\" \"\${container}\"
    "
    assert_success
    assert_output --partial "BRANCH=[]"
    assert_output --partial "CONTAINER=[]"
}

@test "wt_resolve_container_from_cwd: emits '<branch>\\t<container>' when cwd matches AND stack is up" {
    # Happy path: cwd is a registered worktree AND its stack is
    # running. Docker stub emits a container ID for the label-filter
    # ps call; function should emit both branch AND container.
    oc_init_repo "${TMP_ROOT}"
    local wt_dir="${TMP_ROOT}/openemr-wt-my-branch"
    mkdir -p "${wt_dir}"
    oc_init_repo "${wt_dir}"
    cat > "${TMP_ROOT}/.worktrees.json" <<JSON
{"my-branch": {"dir": "${wt_dir}"}}
JSON
    run env LABEL_PS_OUTPUT="wt-container-id" OPENEMR_ROOT="${TMP_ROOT}" \
        WT_STATE_FILE="${TMP_ROOT}/.worktrees.json" \
        PATH="${STUB_DIR}:${PATH}" bash -c "
        set -euo pipefail
        cd '${wt_dir}'
        __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
        IFS=\$'\t' read -r branch container < <(wt_resolve_container_from_cwd)
        printf 'BRANCH=[%s]\nCONTAINER=[%s]\n' \"\${branch}\" \"\${container}\"
    "
    assert_success
    assert_output --partial "BRANCH=[my-branch]"
    assert_output --partial "CONTAINER=[wt-container-id]"
}

# --- prek dispatch: refuse fallback when in a worktree with stack down ----

@test "prek run: cwd IS a worktree, stack DOWN -> exit 1 naming the worktree; refuses CONTAINER_ID fallback" {
    # Regression guard for the silent-misrouting bug: if the caller is
    # inside worktree A (stack down) and worktree B is running, the OLD
    # behavior fell back to B's container. Pre-commit then reported
    # "no files to check" for every hook (B's git index didn't match
    # A's staged files) and the commit went through un-validated.
    # New behavior: fail loud, name worktree A, and do NOT invoke docker exec.
    oc_init_repo "${TMP_ROOT}"
    local wt_dir="${TMP_ROOT}/openemr-wt-my-branch"
    mkdir -p "${wt_dir}"
    oc_init_repo "${wt_dir}"
    cat > "${TMP_ROOT}/.worktrees.json" <<JSON
{"my-branch": {"dir": "${wt_dir}"}}
JSON
    # LABEL_PS_OUTPUT stays empty => the docker stub returns no
    # container for the worktree's label query (stack down).
    # -d some-other-container simulates the fallback target being
    # available; the fix must refuse it.
    run env OPENEMR_ROOT="${TMP_ROOT}" WT_STATE_FILE="${TMP_ROOT}/.worktrees.json" \
        PATH="${STUB_DIR}:${PATH}" bash -c "
        cd '${wt_dir}'
        '${SCRIPT}' -d some-other-container prek run
    "
    assert_failure
    # Error spells out "docker compose stack" (not just "stack") so a
    # git-hook reader who doesn't have openemr-cmd's jargon in working
    # memory can parse it. Names the specific worktree, and mentions
    # BOTH recovery commands (worktree start for previously-up stopped
    # stacks, worktree up for never-up'd / previously-down'd ones);
    # the code doesn't detect which state we're in — user picks based
    # on what they know they did last.
    assert_output --partial "worktree 'my-branch' docker compose stack is not up"
    assert_output --partial "openemr-cmd worktree start my-branch"
    assert_output --partial "openemr-cmd worktree up my-branch"
    assert_output --partial "preserves data"
    # And the "would silently validate wrong checkout" rationale
    # (a load-bearing comment for the next reader tempted to re-add
    # the fallback). The word "silently" and the rest of the phrase
    # span a line break in the actual output, so match each half
    # separately rather than trying to match across the newline.
    assert_output --partial "another running container"
    assert_output --partial "validate the wrong checkout"
    # Must NOT have dispatched to any docker exec (fallback rejected).
    if grep -q "exec .*some-other-container" "${STUB_DIR}/docker.log" 2>/dev/null; then
        cat "${STUB_DIR}/docker.log"
        fail "prek dispatched to the fallback container despite worktree stack being down"
    fi
}

@test "prek run: cwd is NOT a worktree, no matching container -> falls back to CONTAINER_ID (unchanged behavior)" {
    # Reverse case: cwd is NOT a managed worktree (arbitrary dir with
    # a git repo but no .worktrees.json entry). The fallback to
    # CONTAINER_ID (here, the -d value) is correct — that's the path
    # devs use from the primary repo. Pins that we didn't regress
    # non-worktree usage.
    oc_init_repo "${TMP_ROOT}"
    # State file present but doesn't cover this cwd.
    cat > "${TMP_ROOT}/.worktrees.json" <<JSON
{"other-branch": {"dir": "/nonexistent/other"}}
JSON
    run env OPENEMR_ROOT="${TMP_ROOT}" WT_STATE_FILE="${TMP_ROOT}/.worktrees.json" \
        PATH="${STUB_DIR}:${PATH}" bash -c "
        cd '${TMP_ROOT}'
        '${SCRIPT}' -d primary-container prek run
    "
    assert_success
    # Dispatched to the -d container via docker exec.
    grep -Fq "exec -w /var/www/localhost/htdocs/openemr -i primary-container sh -c" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected fallback dispatch to primary-container"; }
    # And must NOT have printed the worktree-stack-down error.
    refute_output --partial "docker compose stack is not up"
}
