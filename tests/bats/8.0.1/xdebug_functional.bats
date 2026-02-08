# BATS: 8.0.1 xdebug.sh — functional tests (validation and exit codes)

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.0.1)"
    XDEBUG="${SCRIPT_DIR}/xdebug.sh"
    [[ -f "$XDEBUG" ]]
}

@test "8.0.1 xdebug: exits 1 when XDEBUG_ON and XDEBUG_IDE_KEY both unset" {
    run env -i PATH="$PATH" HOME="${HOME:-/tmp}" bash "$XDEBUG" 2>&1
    [[ $status -eq 1 ]]
    [[ $output == *"Error"* ]] || [[ $output == *"XDEBUG"* ]] || [[ $output == *"XDebug"* ]]
}

@test "8.0.1 xdebug: exits 1 when XDEBUG_ON not 1 and XDEBUG_IDE_KEY empty" {
    run env XDEBUG_ON=0 XDEBUG_IDE_KEY= bash "$XDEBUG" 2>&1
    [[ $status -eq 1 ]]
    [[ $output == *"Error"* ]] || [[ $output == *"XDEBUG"* ]]
}

@test "8.0.1 xdebug: passes validation when XDEBUG_ON=1" {
    # Script will later try apk/php - we only test that it passes the first validation and exits later (e.g. apk not found) or succeeds in container
    run bash -c "XDEBUG_ON=1 PHP_VERSION_ABBR=84 '$XDEBUG' 2>&1; exit \$?"
    # Either succeeds (0) or fails later on apk/php (non-zero) - but must not exit 1 at validation
    [[ $status -ne 1 ]] || [[ $output != *"neither XDEBUG_ON nor XDEBUG_IDE_KEY"* ]]
}

@test "8.0.1 xdebug: passes validation when XDEBUG_IDE_KEY set" {
    run bash -c "XDEBUG_IDE_KEY=PHPSTORM '$XDEBUG' 2>&1; exit \$?"
    [[ $status -ne 1 ]] || [[ $output != *"neither XDEBUG_ON nor XDEBUG_IDE_KEY"* ]]
}
