# BATS: --base flag of `openemr-cmd worktree add` and the underlying
# wt_resolve_base helper.
#
# Contract under test:
#   --base <url>[#<ref>]    -> fetch from URL, base on FETCH_HEAD
#   --base <git commit-ish> -> pure git rev-parse resolution, no fetch
#   no --base               -> fetch canonical openemr/openemr master
#                              (NOT routed through wt_resolve_base; covered
#                              via the integration-error tests only)

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_ROOT=$(oc_mktempdir)

    # Real local git repo with one commit on master, an extra branch, and
    # a tag. Used both as OPENEMR_ROOT (target of rev-parse) and as a
    # file:// fetch source for URL-form tests.
    oc_init_repo "${TMP_ROOT}"
    git -C "${TMP_ROOT}" branch rel-test
    # tag.gpgsign / tag.forceSignAnnotated in a user's global config would
    # otherwise force annotated+signed tags and prompt for a message.
    git -C "${TMP_ROOT}" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag v-test

    export TMP_ROOT
}

teardown() {
    [[ -n "${TMP_ROOT:-}" ]] && rm -rf "${TMP_ROOT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    # Some tests don't set STUB_DIR, so the [[ -n ]] above can be the
    # teardown's last command and return 1. Force success.
    return 0
}

# Run a wt_resolve_base call in a subshell with the script's function defs
# sourced. Stderr is folded into stdout so assertions on hint messages work.
run_resolve() {
    local arg="$1"
    run env \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WT_CANONICAL_URL="https://github.com/openemr/openemr.git" \
        bash -c "
            set -uo pipefail
            __OPENEMR_CMD_SOURCE_FUNCS_ONLY=1
        source '${SCRIPT}'
            wt_resolve_base '${arg}' 2>&1
        "
}

# --- URL form ---------------------------------------------------------------

@test "wt_resolve_base: file:// URL with #ref fetches and echoes FETCH_HEAD" {
    run_resolve "file://${TMP_ROOT}#master"
    assert_success
    # FETCH_HEAD appears on the last line; the wt_info chatter is above it.
    # A SHA appears on its own line; wt_info chatter is above it. Use
    # assert_line (per-line match) so the anchors work, and a regex so
    # we don't have to plumb the expected SHA in. Bash 3.2 compatible.
    assert_line --regexp '^[0-9a-f]{40}$'
}

@test "wt_resolve_base: file:// URL without #ref defaults to master" {
    run_resolve "file://${TMP_ROOT}"
    assert_success
    # A SHA appears on its own line; wt_info chatter is above it. Use
    # assert_line (per-line match) so the anchors work, and a regex so
    # we don't have to plumb the expected SHA in. Bash 3.2 compatible.
    assert_line --regexp '^[0-9a-f]{40}$'
}

@test "wt_resolve_base: URL fetch failure returns non-zero with 'fetch failed' hint" {
    run_resolve "file:///nonexistent/repo/that/does/not/exist.git#master"
    assert_failure
    assert_output --partial "fetch failed"
}

@test "wt_resolve_base: git@ form is dispatched as URL (not as a local ref)" {
    # We can't actually auth in the test env, so we expect the fetch step
    # to fail. The point is to confirm git@... gets to the fetch branch
    # rather than falling through to rev-parse with the 'is not a URL' hint.
    run_resolve "git@github.com:fake-org-bats/fake-repo-bats.git#master"
    assert_failure
    refute_output --partial "is not a URL"
}

@test "wt_resolve_base: https:// form is dispatched as URL" {
    # Same shape as the git@ test — fetch will fail in the test env (the
    # repo doesn't exist), but we just need to confirm the dispatch.
    run_resolve "https://github.com/fake-org-bats/fake-repo-bats.git#master"
    assert_failure
    refute_output --partial "is not a URL"
}

# --- git-native form --------------------------------------------------------

@test "wt_resolve_base: local branch name resolves to itself (echoed for git worktree add to use)" {
    run_resolve "master"
    assert_success
    assert_output "master"
}

@test "wt_resolve_base: non-master local branch resolves" {
    run_resolve "rel-test"
    assert_success
    assert_output "rel-test"
}

@test "wt_resolve_base: tag resolves" {
    run_resolve "v-test"
    assert_success
    assert_output "v-test"
}

@test "wt_resolve_base: HEAD resolves (explicit opt-in to primary HEAD)" {
    run_resolve "HEAD"
    assert_success
    assert_output "HEAD"
}

@test "wt_resolve_base: full SHA resolves" {
    local sha
    sha=$(git -C "${TMP_ROOT}" rev-parse HEAD)
    run_resolve "${sha}"
    assert_success
    assert_output "${sha}"
}

@test "wt_resolve_base: nonexistent ref fails with helpful canonical-URL hint" {
    run_resolve "nonexistent-branch-xyz"
    assert_failure
    assert_output --partial "is not a URL and does not resolve as a local git ref"
    assert_output --partial "github.com/openemr/openemr.git#nonexistent-branch-xyz"
}

# --- cmd_worktree_add integration ------------------------------------------
# These call the full script as a subprocess to exercise arg parsing and
# the wt_die paths. We don't try to drive a successful worktree creation
# end-to-end (that needs real docker compose dirs, port allocation, etc.);
# the error paths are what guard the user-facing contract.

@test "cmd_worktree_add: --base without -b errors and points at -b requirement" {
    STUB_DIR=$(oc_make_docker_stub_dir)
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="$(dirname "${TMP_ROOT}")" \
        "${SCRIPT}" worktree add somebranch --base master
    assert_failure
    assert_output --partial "--base only applies with -b"
}

@test "cmd_worktree_add: --base unknown ref dies with the canonical-URL hint" {
    STUB_DIR=$(oc_make_docker_stub_dir)
    # Bypass the wt_compose_subdir existence check by creating the dir.
    mkdir -p "${TMP_ROOT}/docker/development-easy"
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="$(dirname "${TMP_ROOT}")" \
        "${SCRIPT}" worktree add feat -b --base nonexistent-xyz
    assert_failure
    assert_output --partial "is not a URL and does not resolve as a local git ref"
    assert_output --partial "github.com/openemr/openemr.git#nonexistent-xyz"
    assert_output --partial "Failed to resolve --base 'nonexistent-xyz'"
}

@test "cmd_worktree_add: --base with no value errors clearly" {
    STUB_DIR=$(oc_make_docker_stub_dir)
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="$(dirname "${TMP_ROOT}")" \
        "${SCRIPT}" worktree add feat -b --base
    assert_failure
    assert_output --partial "--base requires a value"
}

# --- help-block drift guard --------------------------------------------------
# openemr-cmd has TWO worktree-add usage blocks:
#   1. top-level `openemr-cmd -h` (in the main usage block)
#   2. `openemr-cmd worktree` no-subcommand fallback (in cmd_worktree())
# Both must surface --base so users running either get current info.

@test "help drift: top-level -h surfaces --base on the worktree add line" {
    STUB_DIR=$(oc_make_docker_stub_dir)
    run env PATH="${STUB_DIR}:$PATH" "${SCRIPT}" -h
    # USAGE_EXIT_CODE=13; openemr-cmd -h exits non-zero by design.
    assert_output --partial "[--base <ref>]"
}

@test "help drift: 'worktree' (no subcommand) fallback surfaces --base" {
    STUB_DIR=$(oc_make_docker_stub_dir)
    run env \
        PATH="${STUB_DIR}:$PATH" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="$(dirname "${TMP_ROOT}")" \
        "${SCRIPT}" worktree
    assert_failure
    assert_output --partial "[--base <ref>]"
}
