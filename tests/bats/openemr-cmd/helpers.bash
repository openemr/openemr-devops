# Helpers for BATS tests of utilities/openemr-cmd/openemr-cmd.
# Source this in test files: load 'helpers'
#
# Kept separate from tests/bats/helpers.bash so we don't pollute the
# per-image test infrastructure with host-CLI concerns.
#
# shellcheck shell=bash

# Repo root (directory containing utilities/openemr-cmd/openemr-cmd).
oc_repo_root() {
    local dir
    # BATS_TEST_FILENAME is set by the bats runner before sourcing.
    # shellcheck disable=SC2154
    dir="${BATS_TEST_FILENAME%/*}"
    while [[ -n "${dir}" ]] && [[ "${dir}" != "/" ]]; do
        [[ -f "${dir}/utilities/openemr-cmd/openemr-cmd" ]] && echo "${dir}" && return 0
        dir="${dir%/*}"
    done
    return 1
}

# Absolute path to the script under test.
oc_script_path() {
    local root
    root=$(oc_repo_root) || return 1
    echo "${root}/utilities/openemr-cmd/openemr-cmd"
}

# Make a per-test scratch directory. Caller owns cleanup (use trap or teardown).
oc_mktempdir() {
    mktemp -d "${BATS_TMPDIR:-/tmp}/openemr-cmd-XXXXXX"
}

# Build a PATH-stubs directory containing a 'docker' shim that responds to
# 'docker compose' (no args, plugin probe) with exit 0 and ignores everything
# else with empty output and exit 0. The shim does NOT shell out anywhere.
#
# Usage:
#   stub_dir=$(oc_make_docker_stub_dir)
#   PATH="${stub_dir}:$PATH" run "$SCRIPT" worktree list
oc_make_docker_stub_dir() {
    local d
    d=$(oc_mktempdir)
    cat > "${d}/docker" <<'STUB'
#!/bin/sh
# Predictable stub of 'docker' used by openemr-cmd BATS tests.
# 'docker compose' (plugin probe) must succeed so check_docker_compose_install
# picks the plugin path; everything else returns empty/0.
if [ "${1-}" = "compose" ]; then
    exit 0
fi
exit 0
STUB
    chmod +x "${d}/docker"
    echo "${d}"
}

# Line number that marks the end of function definitions in the script
# (the last '}' before USAGE_EXIT_CODE=13 and the dispatch logic). Sourcing
# only the first OC_SCRIPT_FUNCS_END lines gives us a library-like view of
# the script: every function defined, no main-line dispatch executed.
# If the script is restructured, bump this constant — the test
# 'OC_SCRIPT_FUNCS_END points at end of function defs' in helpers_pure.bats
# will fail loudly when it drifts.
OC_SCRIPT_FUNCS_END=1460

# Source ONLY the function definitions of openemr-cmd into the current shell.
# Caller is responsible for setting OPENEMR_ROOT (and WT_STATE_FILE / others
# as needed) BEFORE calling, since the script's top-level OPENEMR_ROOT
# assignment runs while sourcing.
#
# Usage (inside a 'bash -c' inside @test):
#   oc_source_funcs
#   wt_slug feature/foo
oc_source_funcs() {
    local script
    script=$(oc_script_path) || return 1
    # shellcheck disable=SC1090,SC2312
    source <(head -n "${OC_SCRIPT_FUNCS_END}" "${script}")
}

# Initialize $1 as a real git repo with one commit, so commands like
# 'git -C <dir> worktree list --porcelain' and
# 'git -C <dir> symbolic-ref --short HEAD' work.
oc_init_repo() {
    local dir=$1
    git -C "${dir}" init --quiet --initial-branch=master >/dev/null 2>&1 \
        || git -C "${dir}" init --quiet >/dev/null 2>&1
    git -C "${dir}" config user.email "bats@example.com"
    git -C "${dir}" config user.name "bats"
    git -C "${dir}" config commit.gpgsign false
    : > "${dir}/.placeholder"
    git -C "${dir}" add .placeholder
    git -C "${dir}" commit --quiet -m "init" >/dev/null
}

# Register a new git worktree on a new branch under <wt-parent>/<dirname>.
# After this, <wt-parent>/<dirname> exists on disk and
# 'git -C <repo> worktree list --porcelain' shows it.
# Useful for setting up "partial" / "valid" fixtures where the worktree
# is a real registered git worktree but lacks the compose files that
# `openemr-cmd worktree add` would normally generate.
#
# Usage:
#   oc_add_registered_worktree "${REPO}" "${WT_PARENT}" feature/foo
# Args:
#   $1 repo (an OPENEMR_ROOT — must already be oc_init_repo'd)
#   $2 worktree parent directory (where the worktree subdir lands)
#   $3 branch name to create (passed verbatim to `git worktree add -b`)
oc_add_registered_worktree() {
    local repo=$1 wt_parent=$2 branch=$3
    # Slugify branch for the dirname so 'feature/foo' becomes 'feature-foo'
    # (the script's wt_slug rule). This is just for the on-disk path; the
    # branch name registered with git stays as-is.
    local slug
    # shellcheck disable=SC2312
    slug=$(echo "${branch}" | tr '/' '-' | tr -cd 'a-zA-Z0-9_-' | tr '[:upper:]' '[:lower:]')
    local wt_dir="${wt_parent}/openemr-wt-${slug}"
    git -C "${repo}" worktree add --quiet -b "${branch}" "${wt_dir}" >/dev/null
    echo "${wt_dir}"
}
