# BATS: flex pcov.sh — functional tests (validation and exit codes)

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir flex)"
    PCOV="${SCRIPT_DIR}/pcov.sh"
    [[ -f "$PCOV" ]]
}

@test "flex pcov: exits 1 when PCOV_ON is not true" {
    run bash -c "PCOV_ON=false '$PCOV' 2>&1"
    [[ $status -eq 1 ]]
    [[ $output == *"Error: PCOV script called but PCOV_ON is not enabled"* ]]
}

@test "flex pcov: exits 1 when PCOV_ON unset" {
    run bash -c "unset PCOV_ON; '$PCOV' 2>&1"
    [[ $status -eq 1 ]]
}

@test "flex pcov: exits 1 when PCOV_ON=1 (numeric, not true)" {
    # Script expects literal "true" per comment in pcov.sh
    run bash -c "PCOV_ON=1 '$PCOV' 2>&1"
    [[ $status -eq 1 ]]
}

@test "flex pcov: passes validation when PCOV_ON=true" {
    # Will fail later on apk/php (exit 127) unless in container; we only check it doesn't fail at validation
    run bash -c "PCOV_ON=true PHP_VERSION_ABBR=84 '$PCOV' 2>&1"
    # Must not fail with the "PCOV_ON is not enabled" validation message; 127 = apk not found is OK
    [[ $output != *"PCOV_ON is not enabled"* ]]
    [[ $status -ne 1 ]]
}
