# BATS: wt_write_override emits HOST_UID/HOST_GID env vars in the
# openemr service block.
#
# These env vars are consumed by the openemr container's entrypoint
# (added in openemr/openemr#12642) so apache inside the container
# adopts the host's uid/gid for the bind-mounted webroot. Pin both
# (a) the keys are emitted at all (a regression where they vanish
# would silently re-introduce the uid-mismatch class of bugs) and
# (b) the values match `id -u`/`id -g` at the time the override
# was written (so we know the value, not just the key).

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
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

oc_add() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        WT_CANONICAL_URL="file://${TMP_ROOT}" \
        "${SCRIPT}" worktree add "$@"
}

@test "host_uid: wt_write_override emits HOST_UID and HOST_GID env vars in the openemr service block" {
    oc_add hu-env -b --env easy >/dev/null
    local override="${TMP_PARENT}/openemr-wt-hu-env/docker/development-easy/docker-compose.override.yml"
    [[ -f "${override}" ]] || fail "override file missing"

    # Both keys present.
    grep -qE '^[[:space:]]+HOST_UID:[[:space:]]+"[0-9]+"' "${override}" \
        || { echo "--- override.yml ---"; cat "${override}"; fail "HOST_UID env var missing"; }
    grep -qE '^[[:space:]]+HOST_GID:[[:space:]]+"[0-9]+"' "${override}" \
        || { echo "--- override.yml ---"; cat "${override}"; fail "HOST_GID env var missing"; }

    # Values match the runner's current uid/gid (the override was just
    # written by this test invocation).
    local expected_uid expected_gid
    expected_uid=$(id -u)
    expected_gid=$(id -g)
    grep -qE "^[[:space:]]+HOST_UID:[[:space:]]+\"${expected_uid}\"\$" "${override}" \
        || fail "HOST_UID value != id -u (=${expected_uid})"
    grep -qE "^[[:space:]]+HOST_GID:[[:space:]]+\"${expected_gid}\"\$" "${override}" \
        || fail "HOST_GID value != id -g (=${expected_gid})"
}

@test "host_uid: env vars are nested under services.openemr.environment (not under volumes)" {
    oc_add hu-shape -b --env easy >/dev/null
    local override="${TMP_PARENT}/openemr-wt-hu-shape/docker/development-easy/docker-compose.override.yml"
    [[ -f "${override}" ]] || fail "override file missing"

    # Structural check via awk (instead of yq / pyyaml, both of which
    # are inconsistently available across runners — macos GH-hosted
    # runners ship neither). Walk the file linearly:
    #   - Find the start of `services:`
    #   - Inside it, find `openemr:`
    #   - Inside that, find `environment:` before `volumes:`
    #   - Confirm HOST_UID and HOST_GID are nested under environment
    # If `environment:` appears AFTER `volumes:`, the awk's seen_env
    # check would still pass (both blocks belong to openemr), but the
    # standard ordering used by wt_write_override puts env first.
    local result
    result=$(awk '
        /^services:/                   { in_services = 1; next }
        in_services && /^  openemr:/   { in_openemr = 1; next }
        in_openemr && /^  [a-zA-Z]/    { in_openemr = 0; in_env = 0 }
        in_openemr && /^    environment:/ { in_env = 1; next }
        in_openemr && /^    [a-zA-Z]/  { in_env = 0 }
        in_env && /HOST_UID:[[:space:]]+"[0-9]+"/ { seen_uid = 1 }
        in_env && /HOST_GID:[[:space:]]+"[0-9]+"/ { seen_gid = 1 }
        END {
            if (!seen_uid) print "missing HOST_UID under services.openemr.environment"
            else if (!seen_gid) print "missing HOST_GID under services.openemr.environment"
            else print "OK"
        }
    ' "${override}")
    [[ "${result}" = "OK" ]] || { echo "--- override.yml ---"; cat "${override}"; fail "${result}"; }
}

@test "host_uid: emitted for every env (easy / easy-light / easy-redis)" {
    # The HOST_UID block lives in the shared portion of wt_write_override
    # (above the env-specific branches), so all three envs should get it.
    # Regression guard against a refactor that conditionally emits.
    for env in easy easy-light easy-redis; do
        oc_add "hu-${env}" -b --env "${env}" >/dev/null
        local override="${TMP_PARENT}/openemr-wt-hu-${env}/docker/development-${env}/docker-compose.override.yml"
        grep -qE '^[[:space:]]+HOST_UID:[[:space:]]+"[0-9]+"' "${override}" \
            || fail "HOST_UID missing in override for env=${env}"
        grep -qE '^[[:space:]]+HOST_GID:[[:space:]]+"[0-9]+"' "${override}" \
            || fail "HOST_GID missing in override for env=${env}"
    done
}
