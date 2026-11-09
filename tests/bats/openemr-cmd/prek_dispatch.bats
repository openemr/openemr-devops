# BATS: `openemr-cmd prek <args>` subcommand routing.
#
# Unlike the other devtools commands, prek runs Python pre-commit INSIDE
# the openemr container at the openemr workdir. The dispatch chain (line
# ~2304):
#   1. wt_resolve_container_from_cwd: if cwd is inside a managed worktree
#      from .worktrees.json, route to that worktree's openemr container.
#      Otherwise return empty.
#   2. Fall back to CONTAINER_ID (the global one resolved earlier).
#   3. If still empty, surface a "no running openemr container" error.
#   4. Otherwise: docker exec -w /var/www/localhost/htdocs/openemr -i <id>
#      sh -c '<inline-script>' sh <args>
#   5. The inline script substitutes actionlint-docker → actionlint-system
#      ONLY for `run` / `install-hooks` subcommands (which read the config).
#      All other subcommands (--version, --help, autoupdate, etc.) pass
#      through unchanged.
#
# The inline script runs IN the container; our stub only records the
# outer `docker exec` invocation. So these tests pin:
#   - the outer dispatch shape (-w, -i, container id, sh -c, args)
#   - the inline script contains the actionlint substitution logic
#   - the no-container error path

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load 'helpers'

setup() {
    SCRIPT="$(oc_script_path)"
    [[ -x "$SCRIPT" ]] || skip "openemr-cmd script not found"
    STUB_DIR=$(oc_make_docker_stub_dir)
    CONTAINER=fixed-prek-target
    export STUB_DIR CONTAINER
}

teardown() {
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "${STUB_DIR}"
    return 0
}

# Run via -d so CONTAINER_ID is fixed (skipping the auto-detect chain).
oc_run() {
    env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" -d "${CONTAINER}" "$@"
}

# --- outer dispatch shape --------------------------------------------------
# The recorded docker.log captures `docker exec ...` invocations via
# `echo "$@"`. The inline script for prek contains newlines, so a single
# invocation spans multiple log lines: the FIRST line starts with
# `exec -w /var/www/localhost/htdocs/openemr -i <id> sh -c`, the MIDDLE
# lines are the inline script body, and the LAST line is the trailing
# `sh <args>` (positional args to the inline sh). Anchor the
# "trailing-args" check to the last line of the log.

@test "prek run: 'docker exec -w /var/www/localhost/htdocs/openemr -i <id> sh -c <script> sh run'" {
    run oc_run prek run
    assert_success
    grep -Fq "exec -w /var/www/localhost/htdocs/openemr -i ${CONTAINER} sh -c" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected 'exec -w .../openemr -i ${CONTAINER} sh -c' invocation"; }
    grep -Eq '[[:space:]]sh run$' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected trailing 'sh run' (positional args to inline sh)"; }
}

@test "prek install-hooks: same outer dispatch, args pass through to inline sh" {
    run oc_run prek install-hooks
    assert_success
    grep -Fq "exec -w /var/www/localhost/htdocs/openemr -i ${CONTAINER} sh -c" "${STUB_DIR}/docker.log" \
        || fail "expected docker exec dispatch"
    grep -Eq '[[:space:]]sh install-hooks$' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected trailing 'sh install-hooks'"; }
}

@test "prek run --all-files phpstan: args after the subcommand are also forwarded" {
    run oc_run prek run --all-files phpstan
    assert_success
    grep -Fq "exec -w /var/www/localhost/htdocs/openemr -i ${CONTAINER} sh -c" "${STUB_DIR}/docker.log" \
        || fail "expected docker exec dispatch"
    grep -Eq '[[:space:]]sh run --all-files phpstan$' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected trailing 'sh run --all-files phpstan'"; }
}

@test "prek --version: pass-through path (no actionlint substitution required)" {
    run oc_run prek --version
    assert_success
    grep -Fq "exec -w /var/www/localhost/htdocs/openemr -i ${CONTAINER} sh -c" "${STUB_DIR}/docker.log" \
        || fail "expected docker exec dispatch"
    grep -Eq '[[:space:]]sh --version$' "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "expected trailing 'sh --version'"; }
}

# --- inline script contains the actionlint substitution + pass-through ----
# The stub records the full `docker exec ... sh -c '<inline-script>' sh
# <args>` line, including the inline script source. We grep that line for
# the substitution signal so a refactor that drops the swap doesn't slip
# past unnoticed.

@test "prek dispatch: inline script substitutes actionlint-docker -> actionlint-system" {
    run oc_run prek run
    assert_success
    grep -Fq "actionlint-docker" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'actionlint-docker' source"; }
    grep -Fq "actionlint-system" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'actionlint-system' replacement"; }
    grep -Fq "sed " "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'sed' substitution command"; }
}

@test "prek dispatch: inline script rewrites 'php bin/console' entries to drop to apache" {
    # bin/console has RootCliGuard::assertNotRoot(); the in-container prek
    # dispatch runs as root by default, so any hook whose entry is
    # `php bin/console ...` (currently license-headers from openemr#15088)
    # would fatal. The inline sed drops those entries to apache via su-exec
    # so the guard passes. Host-direct prek is not affected: that runs as
    # the developer's uid, which already passes the guard without a rewrite.
    run oc_run prek run
    assert_success
    grep -Fq "entry: php bin/console" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'entry: php bin/console' source pattern"; }
    grep -Fq "entry: su-exec apache php bin/console" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'entry: su-exec apache php bin/console' replacement"; }
}

@test "prek dispatch: inline script handles run + install-hooks vs the pass-through default" {
    # The script's case body should mention 'run' and 'install-hooks'
    # explicitly (the substitution subjects) AND `exec pre-commit "$@"`
    # as the pass-through path. All three live in the same inline string,
    # so grepping the recorded line covers the inline-script structure.
    run oc_run prek run
    assert_success
    grep -Fq "run|install-hooks" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'run|install-hooks' case"; }
    grep -Fq "exec pre-commit" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing 'exec pre-commit' pass-through"; }
    # And the --config <tmp> form that's specific to the substituted-config path.
    grep -Fq -- "--config" "${STUB_DIR}/docker.log" \
        || { cat "${STUB_DIR}/docker.log"; fail "inline script missing '--config <tmp>' usage"; }
}

# --- no-container error path ----------------------------------------------

@test "prek: when no container is running, surfaces 'no running openemr container'" {
    # No -d, no auto-detected container (default empty DOCKER_PS_OUTPUT) →
    # CONTAINER_ID is empty and the case-block check at line ~2331 fires.
    # The script's container-resolution layer also surfaces its own error
    # earlier (line ~2008) for commands that need CONTAINER_ID, so a bare
    # `openemr-cmd prek` hits that path first. We assert the SECOND-line
    # one fires when we bypass via -d empty-id... but -d requires a value.
    # So we test the natural path: no -d, no running container → the
    # earlier "Could not automatically determine target OpenEMR container"
    # error fires before reaching prek's own check. That's expected — the
    # outer check is more general.
    run env PATH="${STUB_DIR}:${PATH}" "${SCRIPT}" prek run
    assert_failure
    assert_output --partial "Could not automatically determine target OpenEMR container"
}
