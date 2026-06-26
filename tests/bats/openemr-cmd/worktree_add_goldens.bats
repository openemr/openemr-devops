# BATS: golden-file snapshots for the artifacts cmd_worktree_add generates.
#
# Where worktree_add_integration.bats sampled individual lines / values
# (WT_HTTP_PORT=8301, the openemr-<slug>_db volume name, etc.), this file
# snapshots the WHOLE generated file and diffs against a checked-in golden.
# Any drift in the shape of .env / docker-compose.override.yml /
# .worktrees.json — whitespace, ordering, header comments, line counts —
# trips the test. Useful for catching accidental refactors that intend to
# be cosmetic but actually change the layout other tooling reads from.
#
# Goldens live in tests/bats/openemr-cmd/goldens/<env>/<artifact>. To
# (re)generate them after an intentional shape change:
#
#   UPDATE_GOLDENS=1 /tmp/bats/bin/bats \
#     tests/bats/openemr-cmd/worktree_add_goldens.bats
#
# Inspect the diff (`git diff tests/bats/openemr-cmd/goldens/`) before
# committing — the bless mode trusts whatever the script currently emits.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

GOLDENS_DIR="$(cd "${BATS_TEST_FILENAME%/*}" && pwd)/goldens"

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    TMP_ROOT="${TMP_PARENT}/primary"
    mkdir -p "${TMP_ROOT}"
    oc_init_repo_with_fixtures "${TMP_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    export TMP_PARENT TMP_ROOT STUB_DIR
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

run_add() {
    run env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "$@"
}

# Mask the runtime-variable TMP_PARENT prefix so the golden is reproducible
# across machines/runs. Inside the masked prefix everything is stable
# (TMP_ROOT = TMP_PARENT/primary, worktrees at TMP_PARENT/openemr-wt-*).
#
# Takes TMP_PARENT as an argument rather than hardcoding the platform-specific
# mktemp prefix (Linux /tmp vs. macOS /var/folders/.../T). Also substitutes
# the realpath-resolved form: on macOS /var/folders/... resolves to
# /private/var/folders/... because /var is itself a symlink, and the
# override.yml has paths produced via realpath that leak the /private prefix.
# On Linux the resolved form equals the original so the extra sed is a no-op.
mask_paths() {
    local tmp_parent=$1
    local tmp_parent_real
    tmp_parent_real=$(realpath "${tmp_parent}" 2>/dev/null || echo "${tmp_parent}")
    local host_uid host_gid
    host_uid=$(id -u)
    host_gid=$(id -g)
    # Longer (resolved) form first so it can't be partially matched by the shorter one.
    # HOST_UID/HOST_GID values are masked to __HOST_UID__/__HOST_GID__ so
    # goldens stay stable across runner uids (CI=1001, dev box=1000, etc.)
    # without UPDATE_GOLDENS needing to run on each contributor's machine.
    sed -e "s|${tmp_parent_real}|__TMP_PARENT__|g" \
        -e "s|${tmp_parent}|__TMP_PARENT__|g" \
        -e "s|HOST_UID: \"${host_uid}\"|HOST_UID: \"__HOST_UID__\"|g" \
        -e "s|HOST_GID: \"${host_gid}\"|HOST_GID: \"__HOST_GID__\"|g"
}

# Compare ${actual_file} against the golden at ${golden_path}. If
# UPDATE_GOLDENS is set, write the masked actual to the golden path and
# pass the test (used to bless new/changed goldens). Otherwise diff.
assert_matches_golden() {
    local actual_file=$1 golden_path=$2
    local actual_masked
    actual_masked=$(mask_paths "${TMP_PARENT}" < "${actual_file}")
    if [[ -n "${UPDATE_GOLDENS:-}" ]]; then
        mkdir -p "$(dirname "${golden_path}")"
        printf '%s\n' "${actual_masked}" > "${golden_path}"
        echo "BLESSED: ${golden_path}"
        return 0
    fi
    [[ -f "${golden_path}" ]] || \
        fail "golden missing: ${golden_path} — run with UPDATE_GOLDENS=1 to bless"
    local expected_masked
    expected_masked=$(cat "${golden_path}")
    if [[ "${actual_masked}" != "${expected_masked}" ]]; then
        echo "--- expected (golden) ---"
        echo "${expected_masked}"
        echo "--- actual (masked) ---"
        echo "${actual_masked}"
        echo "--- diff ---"
        diff <(echo "${expected_masked}") <(echo "${actual_masked}") || true
        fail "drift vs ${golden_path#${GOLDENS_DIR}/}"
    fi
}

# --- .env (one per env) -----------------------------------------------------

@test "golden: easy .env at offset 1" {
    run_add golden-easy -b
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy/docker/development-easy/.env" \
        "${GOLDENS_DIR}/easy/env"
}

@test "golden: easy-light .env at offset 1" {
    run_add golden-easy-light -b --env easy-light
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy-light/docker/development-easy-light/.env" \
        "${GOLDENS_DIR}/easy-light/env"
}

@test "golden: easy-redis .env at offset 1" {
    run_add golden-easy-redis -b --env easy-redis
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy-redis/docker/development-easy-redis/.env" \
        "${GOLDENS_DIR}/easy-redis/env"
}

# --- override.yml (one per env) ---------------------------------------------

@test "golden: easy docker-compose.override.yml at offset 1" {
    run_add golden-easy -b
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy/docker/development-easy/docker-compose.override.yml" \
        "${GOLDENS_DIR}/easy/override.yml"
}

@test "golden: easy-light docker-compose.override.yml at offset 1" {
    run_add golden-easy-light -b --env easy-light
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy-light/docker/development-easy-light/docker-compose.override.yml" \
        "${GOLDENS_DIR}/easy-light/override.yml"
}

@test "golden: easy-redis docker-compose.override.yml at offset 1" {
    run_add golden-easy-redis -b --env easy-redis
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy-redis/docker/development-easy-redis/docker-compose.override.yml" \
        "${GOLDENS_DIR}/easy-redis/override.yml"
}

# --- .worktrees.json (one — shape is uniform across envs) -------------------

@test "golden: .worktrees.json after a single add" {
    run_add golden-easy -b
    assert_success
    assert_matches_golden \
        "${TMP_ROOT}/.worktrees.json" \
        "${GOLDENS_DIR}/state/single-easy.json"
}

# --- offset increments correctly --------------------------------------------
# Sample test: at offset 2 (after a prior add), .env port lines should all
# be base+2 instead of base+1. The bless-and-diff loop catches port math
# regressions that hand-asserting individual ports can't (e.g., a typo on
# any line of wt_write_env).

@test "golden: easy .env at offset 2 (verifies port arithmetic)" {
    run_add prior -b   # consumes offset 1
    assert_success
    run_add golden-easy-offset2 -b
    assert_success
    assert_matches_golden \
        "${TMP_PARENT}/openemr-wt-golden-easy-offset2/docker/development-easy/.env" \
        "${GOLDENS_DIR}/easy/env-offset-2"
}
