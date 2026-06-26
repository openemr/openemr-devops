# BATS: volume-mount-point pre-create + probe-loosening behavior.
#
# Covers two related changes to cmd_worktree_add / cmd_worktree_set_env /
# cmd_worktree_remove:
#
#   (1) wt_precreate_volume_mountpoints parses each env's
#       docker-compose.yml for volume mounts that target paths under
#       /var/www/localhost/htdocs/openemr/ and pre-creates the host-side
#       dirs as the current user. Without this, docker creates the missing
#       mount-point dirs on the host as root:root 0755 when first
#       attaching a named volume — those empty root-owned dirs then trip
#       the writability probe in cmd_worktree_remove.
#
#   (2) cmd_worktree_remove's writability probe correctly accepts the
#       case where a non-writable dir is EMPTY and its parent is writable
#       (rm only needs to rmdir, which uses the parent's write+execute,
#       not the child's write bit). The probe still fails for non-empty
#       non-writable dirs since rm there would genuinely fail mid-walk.
#
# These tests don't exercise docker — the stub script accepts every call
# and emits nothing — so the precreate dirs come from openemr-cmd's own
# pre-create step, not from the docker daemon.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

# Custom fixture: realistic compose files with volume mounts that mirror
# the actual openemr/openemr docker-compose.yml shape. Required because
# the default oc_init_repo_with_fixtures writes placeholder compose
# files with no volume entries — those would make precreate a no-op and
# leave the tests unable to assert anything.
mp_init_repo() {
    local dir=$1
    oc_init_repo "${dir}"
    mkdir -p "${dir}/docker/library"
    : > "${dir}/docker/library/.placeholder"
    local env
    for env in easy easy-light easy-redis; do
        mkdir -p "${dir}/docker/development-${env}"
        cat > "${dir}/docker/development-${env}/docker-compose.yml" <<'COMPOSE'
services:
  openemr:
    volumes:
    - ${OPENEMR_DIR:-../..}:/openemr:ro
    - ${OPENEMR_DIR:-../..}:/var/www/localhost/htdocs/openemr:rw
    - assetvolume:/var/www/localhost/htdocs/openemr/public/assets:rw
    - themevolume:/var/www/localhost/htdocs/openemr/public/themes:rw
    - sitesvolume:/var/www/localhost/htdocs/openemr/sites:rw
    - nodemodules:/var/www/localhost/htdocs/openemr/node_modules:rw
    - vendordir:/var/www/localhost/htdocs/openemr/vendor:rw
    - phpstanvolume:/var/www/localhost/htdocs/openemr/tmp-phpstan:rw
    - webpackcachevolume:/var/www/localhost/htdocs/openemr/.webpack-cache:rw
    - ccdanodemodules:/var/www/localhost/htdocs/openemr/ccdaservice/node_modules:rw
    - ccdanodemodules2:/var/www/localhost/htdocs/openemr/ccdaservice/packages/oe-cqm-service/node_modules:rw
    - logvolume:/var/log
    - couchdbvolume:/couchdb/data
COMPOSE
    done
    git -C "${dir}" add docker
    git -C "${dir}" commit --quiet -m "fixture: compose with realistic volume mounts"
}

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    TMP_PARENT=$(oc_mktempdir)
    TMP_ROOT="${TMP_PARENT}/primary"
    mkdir -p "${TMP_ROOT}"
    mp_init_repo "${TMP_ROOT}"
    STUB_DIR=$(oc_make_docker_stub_dir)
    STATE_FILE="${TMP_ROOT}/.worktrees.json"
    export TMP_PARENT TMP_ROOT STUB_DIR STATE_FILE
}

teardown() {
    # Restore user write on any chmod-0555 dirs (the probe-loosening tests
    # below create those to simulate root-owned dirs without needing sudo).
    # Without this, rm -rf in cleanup would fail on the non-empty 0555 case.
    [[ -n "${TMP_PARENT:-}" ]] && find "${TMP_PARENT}" -type d -exec chmod u+rwx {} + 2>/dev/null
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

oc_remove() {
    env \
        PATH="${STUB_DIR}:${PATH}" \
        OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree remove "$@"
}

# --- pre-create behavior ----------------------------------------------------

@test "precreate: worktree add creates host-side dirs for all volume mounts under the webroot" {
    oc_add pc-add -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-pc-add"
    # Every named-volume target under /var/www/localhost/htdocs/openemr/
    # in the fixture compose should have a matching pre-created host dir.
    for sub in \
            public/assets \
            public/themes \
            sites \
            node_modules \
            vendor \
            tmp-phpstan \
            .webpack-cache \
            ccdaservice/node_modules \
            ccdaservice/packages/oe-cqm-service/node_modules; do
        [[ -d "${wt}/${sub}" ]] || fail "expected pre-created dir missing: ${sub}"
    done
}

@test "precreate: does NOT create dirs for volumes targeting paths OUTSIDE the webroot" {
    oc_add pc-out -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-pc-out"
    # logvolume → /var/log and couchdbvolume → /couchdb/data are NOT
    # under the webroot, so no host-side dir should be created for them.
    [[ ! -d "${wt}/var" ]] || fail "should not pre-create host dir for /var/log mount"
    [[ ! -d "${wt}/couchdb" ]] || fail "should not pre-create host dir for /couchdb/data mount"
}

@test "precreate: does NOT match the bind mount line itself (target is /var/www/.../openemr with no subpath)" {
    oc_add pc-bind -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-pc-bind"
    # The bind mount `${OPENEMR_DIR:-../..}:/var/www/localhost/htdocs/openemr:rw`
    # has no subpath after openemr — our regex requires `/openemr/` + at
    # least one non-`:` char. Confirm we didn't try to mkdir something
    # weird at the worktree root level.
    [[ ! -d "${wt}/openemr" ]] || fail "should not create stray dir from bind mount line"
}

@test "precreate: regen also pre-creates dirs (env switch via regen path)" {
    oc_add pc-regen -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-pc-regen"
    # Delete a precreate dir to simulate user/tooling cleanup, then regen
    # to confirm the precreate runs from the regen path too.
    rm -rf "${wt}/node_modules"
    [[ ! -d "${wt}/node_modules" ]] || fail "fixture: node_modules should be gone before regen"
    run env PATH="${STUB_DIR}:${PATH}" OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree regen pc-regen
    assert_success
    [[ -d "${wt}/node_modules" ]] || fail "regen did not re-pre-create node_modules"
}

@test "precreate: idempotent — re-running on existing dirs is a no-op" {
    oc_add pc-idem -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-pc-idem"
    # Add a marker file inside a pre-created dir, then regen, then
    # confirm the marker survived (idempotent: mkdir -p doesn't reset
    # existing dirs).
    echo "marker" > "${wt}/vendor/marker.txt"
    run env PATH="${STUB_DIR}:${PATH}" OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree regen pc-idem
    assert_success
    [[ -f "${wt}/vendor/marker.txt" ]] || fail "regen reset existing dir content"
    [[ "$(cat "${wt}/vendor/marker.txt")" = "marker" ]] || fail "marker content changed"
}

@test "precreate: refuses to descend through a symlinked path component (no traversal outside worktree)" {
    # Simulate a malicious-branch scenario where one of the volume
    # mount target's path components is committed as a symlink. The
    # naive `mkdir -p $dir/public/assets` would follow the symlink
    # and create `assets` at the symlink target — outside the worktree.
    # Pre-create's component-walk must refuse to descend through the
    # symlink and abandon that mount target instead.
    oc_add pc-symlink -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-pc-symlink"
    # Stage a sentinel target outside the worktree so we can detect
    # any traversal.
    local outside="${TMP_PARENT}/outside-victim"
    mkdir -p "${outside}"

    # Replace the existing `public` dir (created by precreate) with a
    # symlink pointing outside the worktree. Then re-run precreate via
    # regen to trigger the walk against the now-symlinked component.
    rm -rf "${wt}/public"
    ln -s "${outside}" "${wt}/public"

    run env PATH="${STUB_DIR}:${PATH}" OPENEMR_ROOT="${TMP_ROOT}" \
        WORKTREE_PARENT="${TMP_PARENT}" \
        "${SCRIPT}" worktree regen pc-symlink
    assert_success

    # Sentinel: pre-create must NOT have created `assets` (or anything
    # else from the symlinked component) at the symlink target.
    [[ ! -e "${outside}/assets" ]] \
        || fail "traversal: precreate created '${outside}/assets' via the symlinked 'public' component"
    [[ ! -e "${outside}/themes" ]] \
        || fail "traversal: precreate created '${outside}/themes' via the symlinked 'public' component"
}

# --- probe loosening -------------------------------------------------------

@test "remove probe: passes when non-writable dir is EMPTY and parent is writable (rmdir-able case)" {
    oc_add probe-empty -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-probe-empty"
    # Simulate the docker-daemon-creates-empty-root-owned-dir case. Can't
    # actually chown to root without sudo, but chmod 0555 removes the
    # write bit even for the owner — so `[[ -w "${dir}" ]]` correctly
    # returns false. Parent (`${wt}`) is still writable; dir is empty.
    # Probe should accept (rm could rmdir this).
    mkdir -p "${wt}/probe-blocker"
    chmod 0555 "${wt}/probe-blocker"

    run oc_remove probe-empty <<< 'y'
    # Restore perms before any assertion failure so teardown can clean up.
    chmod 0755 "${wt}/probe-blocker" 2>/dev/null || true
    assert_success
    refute_output --partial "is not writable by you"
}

@test "remove probe: still fails when non-writable dir is NON-EMPTY (rm would actually fail)" {
    oc_add probe-full -b --env easy >/dev/null
    local wt="${TMP_PARENT}/openemr-wt-probe-full"
    # Non-empty 0555 dir: rm can't unlink the file inside without write
    # on the dir itself. Probe MUST still flag this — silently passing
    # would let `git worktree remove --force` fail mid-walk and leave
    # partial state on disk.
    mkdir -p "${wt}/probe-blocker"
    touch "${wt}/probe-blocker/contents"
    chmod 0555 "${wt}/probe-blocker"

    run oc_remove probe-full <<< 'y'
    chmod 0755 "${wt}/probe-blocker" 2>/dev/null || true
    assert_failure
    assert_output --partial "is not writable by you"
    assert_output --partial "probe-blocker"
}
