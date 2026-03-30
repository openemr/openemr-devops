# BATS: 8.1.0 xdebug.sh — functional tests (validation and exit codes)

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'
load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.1.0)"
    XDEBUG="${SCRIPT_DIR}/xdebug.sh"
    [[ -f "$XDEBUG" ]]
}

@test "8.1.0 xdebug: exits 1 when XDEBUG_ON and XDEBUG_IDE_KEY both unset" {
    run env -i PATH="$PATH" HOME="${HOME:-/tmp}" bash "$XDEBUG" 2>&1
    assert_failure 1
    assert_output --partial "neither XDEBUG_ON nor XDEBUG_IDE_KEY"
}

@test "8.1.0 xdebug: exits 1 when XDEBUG_ON not 1 and XDEBUG_IDE_KEY empty" {
    run env XDEBUG_ON=0 XDEBUG_IDE_KEY= bash "$XDEBUG" 2>&1
    assert_failure 1
    assert_output --partial "neither XDEBUG_ON nor XDEBUG_IDE_KEY"
}
