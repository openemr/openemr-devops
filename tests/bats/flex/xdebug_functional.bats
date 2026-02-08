# BATS: flex xdebug.sh — functional tests (validation and exit codes)

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir flex)"
    XDEBUG="${SCRIPT_DIR}/xdebug.sh"
    [[ -f "$XDEBUG" ]]
}

@test "flex xdebug: exits 1 when XDEBUG_ON and XDEBUG_IDE_KEY both unset" {
    run env -i PATH="$PATH" HOME="${HOME:-/tmp}" bash "$XDEBUG" 2>&1
    [[ $status -eq 1 ]]
    [[ $output == *"Error"* ]] || [[ $output == *"XDEBUG"* ]] || [[ $output == *"XDebug"* ]]
}

@test "flex xdebug: exits 1 when XDEBUG_ON not 1 and XDEBUG_IDE_KEY empty" {
    run env XDEBUG_ON=0 XDEBUG_IDE_KEY= bash "$XDEBUG" 2>&1
    [[ $status -eq 1 ]]
    [[ $output == *"Error"* ]] || [[ $output == *"XDEBUG"* ]]
}

@test "flex xdebug: passes validation when XDEBUG_ON=1" {
    run bash -c "XDEBUG_ON=1 PHP_VERSION_ABBR=84 '$XDEBUG' 2>&1" || true
    [[ $output != *"neither XDEBUG_ON nor XDEBUG_IDE_KEY"* ]]
}

@test "flex xdebug: passes validation when XDEBUG_IDE_KEY set" {
    run bash -c "XDEBUG_IDE_KEY=PHPSTORM '$XDEBUG' 2>&1" || true
    [[ $output != *"neither XDEBUG_ON nor XDEBUG_IDE_KEY"* ]]
}
