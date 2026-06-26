# BATS: non-worktree `up` exports HOST_UID/HOST_GID and pre-creates
# volume mount-point dirs.
#
# Companion to host_uid_compose.bats (which covers the worktree-side
# emit via wt_write_override). This file pins the parallel mechanism
# for the non-worktree path: `openemr-cmd up` invoked from a
# docker/development-*/ directory should:
#   1. Export HOST_UID/HOST_GID for compose's env interpolation
#      (consumed by the openemr service's environment block, added in
#      openemr/openemr#12647).
#   2. Pre-create host-side dirs for named-volume mount points under
#      the webroot bind mount (same defense as wt_precreate_volume_
#      mountpoints, but for the base repo path).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

# Build a docker stub that records compose-invocation environment
# vars to a side-file (`docker.env`) alongside the existing arg log.
# The standard oc_make_docker_stub_dir only records args; we need
# env for these tests.
mk_env_recording_stub() {
    local d log env_log
    d=$(oc_mktempdir)
    log="${d}/docker.log"
    env_log="${d}/docker.env"
    : > "${log}"
    : > "${env_log}"
    cat > "${d}/docker" <<STUB
#!/bin/sh
echo "\$@" >> "${log}"
case " \$* " in
    *' ps '*) [ -n "\${DOCKER_PS_OUTPUT-}" ] && echo "\${DOCKER_PS_OUTPUT}" ;;
esac
# Record HOST_UID/HOST_GID at every invocation — used by the env-
# export assertions below to confirm the script exported them before
# calling the compose binary.
env | grep -E '^HOST_(UID|GID)=' >> "${env_log}" || true
exit 0
STUB
    chmod +x "${d}/docker"
    echo "${d}"
}

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    BASE_REPO="${TMP_PARENT}/openemr"
    mkdir -p "${BASE_REPO}/docker/development-easy"
    # Realistic compose with volume mounts (mirrors openemr master).
    cat > "${BASE_REPO}/docker/development-easy/docker-compose.yml" <<'COMPOSE'
services:
  openemr:
    volumes:
    - ${OPENEMR_DIR:-../..}:/var/www/localhost/htdocs/openemr:rw
    - assetvolume:/var/www/localhost/htdocs/openemr/public/assets:rw
    - nodemodules:/var/www/localhost/htdocs/openemr/node_modules:rw
    - vendordir:/var/www/localhost/htdocs/openemr/vendor:rw
    - logvolume:/var/log
    environment:
      HOST_UID: "${HOST_UID:-1000}"
      HOST_GID: "${HOST_GID:-1000}"
COMPOSE
    export TMP_PARENT BASE_REPO
}

teardown() {
    [[ -n "${TMP_PARENT:-}" ]] && rm -rf "${TMP_PARENT}"
    return 0
}

# --- HOST_UID/HOST_GID export ---------------------------------------------

@test "non-worktree up: exports HOST_UID/HOST_GID for docker compose" {
    local stub_dir expected_uid expected_gid
    stub_dir=$(mk_env_recording_stub)
    expected_uid=$(id -u)
    expected_gid=$(id -g)

    # Invoke `openemr-cmd up` from the dev-compose dir against the stub.
    run env -i HOME="${HOME:-/tmp}" PATH="${stub_dir}:${PATH}" \
        bash -c "cd '${BASE_REPO}/docker/development-easy' && '${SCRIPT}' up"
    assert_success

    # The stub's env_log should contain HOST_UID + HOST_GID matching
    # the runner's current uid/gid.
    [[ -f "${stub_dir}/docker.env" ]] || fail "stub didn't record env"
    grep -qE "^HOST_UID=${expected_uid}$" "${stub_dir}/docker.env" \
        || { echo "--- docker.env ---"; cat "${stub_dir}/docker.env"; fail "HOST_UID=${expected_uid} not exported"; }
    grep -qE "^HOST_GID=${expected_gid}$" "${stub_dir}/docker.env" \
        || { echo "--- docker.env ---"; cat "${stub_dir}/docker.env"; fail "HOST_GID=${expected_gid} not exported"; }

    rm -rf "${stub_dir}"
}

@test "non-worktree up: respects user-exported HOST_UID/HOST_GID (doesn't override)" {
    local stub_dir
    stub_dir=$(mk_env_recording_stub)

    # User explicitly exports HOST_UID/HOST_GID before running.
    # Script should use those values, NOT auto-derive from id -u.
    run env -i HOME="${HOME:-/tmp}" PATH="${stub_dir}:${PATH}" \
        HOST_UID=2000 HOST_GID=2000 \
        bash -c "cd '${BASE_REPO}/docker/development-easy' && '${SCRIPT}' up"
    assert_success

    grep -qE "^HOST_UID=2000$" "${stub_dir}/docker.env" \
        || { echo "--- docker.env ---"; cat "${stub_dir}/docker.env"; fail "user HOST_UID=2000 was overridden"; }
    grep -qE "^HOST_GID=2000$" "${stub_dir}/docker.env" \
        || { echo "--- docker.env ---"; cat "${stub_dir}/docker.env"; fail "user HOST_GID=2000 was overridden"; }

    rm -rf "${stub_dir}"
}

# --- Non-worktree pre-create ---------------------------------------------

@test "non-worktree up: pre-creates host-side volume mount-point dirs in the base repo" {
    local stub_dir
    stub_dir=$(mk_env_recording_stub)

    # Confirm the dirs don't exist BEFORE `up`.
    [[ ! -d "${BASE_REPO}/public/assets" ]] || fail "fixture: public/assets exists pre-up"
    [[ ! -d "${BASE_REPO}/node_modules" ]] || fail "fixture: node_modules exists pre-up"
    [[ ! -d "${BASE_REPO}/vendor" ]] || fail "fixture: vendor exists pre-up"

    run env -i HOME="${HOME:-/tmp}" PATH="${stub_dir}:${PATH}" \
        bash -c "cd '${BASE_REPO}/docker/development-easy' && '${SCRIPT}' up"
    assert_success

    # All host-side mount-point dirs created.
    [[ -d "${BASE_REPO}/public/assets" ]] || fail "pre-create missed public/assets"
    [[ -d "${BASE_REPO}/node_modules" ]] || fail "pre-create missed node_modules"
    [[ -d "${BASE_REPO}/vendor" ]] || fail "pre-create missed vendor"
    # Out-of-webroot mount target NOT created on the host (only
    # /var/log inside the container; nothing on the host).
    [[ ! -d "${BASE_REPO}/var" ]] || fail "out-of-webroot dir wrongly created"

    rm -rf "${stub_dir}"
}

@test "non-worktree up: pre-create is idempotent against existing dirs (including root-owned legacy cruft)" {
    local stub_dir
    stub_dir=$(mk_env_recording_stub)

    # Simulate legacy base-repo state: vendor dir already exists.
    # mkdir is the same effect as if a previous `up` had created it
    # (or in the real-world case, an older docker daemon had created
    # it as root); the bats test can't sudo to create as root, but
    # the script's mkdir-then-accept logic doesn't distinguish — it
    # just needs the dir to exist as a real directory.
    mkdir -p "${BASE_REPO}/vendor"
    echo "preserve-me" > "${BASE_REPO}/vendor/marker.txt"

    run env -i HOME="${HOME:-/tmp}" PATH="${stub_dir}:${PATH}" \
        bash -c "cd '${BASE_REPO}/docker/development-easy' && '${SCRIPT}' up"
    assert_success

    # Existing dir + content preserved (mkdir -p is a no-op on existing dirs).
    [[ -d "${BASE_REPO}/vendor" ]] || fail "existing vendor dir wrongly removed"
    [[ -f "${BASE_REPO}/vendor/marker.txt" ]] || fail "marker wrongly removed"
    [[ "$(cat "${BASE_REPO}/vendor/marker.txt")" = "preserve-me" ]] || fail "marker content changed"
    # Other dirs still created.
    [[ -d "${BASE_REPO}/public/assets" ]] || fail "pre-create missed public/assets"

    rm -rf "${stub_dir}"
}
