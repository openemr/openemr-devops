# BATS tests for OpenEMR Docker 8.1.0 bash scripts

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.1.0)"
    [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR" ]]
}

@test "8.1.0: script directory exists" {
    [[ -d "$SCRIPT_DIR" ]]
}

@test "8.1.0: openemr.sh exists and has valid syntax" {
    assert_script_syntax "${SCRIPT_DIR}/openemr.sh"
}

@test "8.1.0: openemr.sh uses bash and sources devtoolsLibrary" {
    assert_script_contains "${SCRIPT_DIR}/openemr.sh" 'devtoolsLibrary.source'
    assert_script_contains "${SCRIPT_DIR}/openemr.sh" 'set -euo pipefail'
}

@test "8.1.0: openemr.sh defines OE_ROOT and AUTO_CONFIG" {
    assert_script_contains "${SCRIPT_DIR}/openemr.sh" 'OE_ROOT='
    assert_script_contains "${SCRIPT_DIR}/openemr.sh" 'AUTO_CONFIG='
}

@test "8.1.0: ssl.sh exists and has valid syntax" {
    assert_script_syntax "${SCRIPT_DIR}/ssl.sh"
}

@test "8.1.0: ssl.sh handles self-signed certificate" {
    assert_script_contains "${SCRIPT_DIR}/ssl.sh" 'selfsigned'
}

@test "8.1.0: xdebug.sh exists and has valid syntax" {
    assert_script_syntax "${SCRIPT_DIR}/xdebug.sh"
}

@test "8.1.0: kcov-wrapper.sh exists and has valid syntax" {
    assert_script_syntax "${SCRIPT_DIR}/kcov-wrapper.sh"
}

@test "8.1.0: utilities/unlock_admin.sh exists and has valid syntax" {
    assert_script_syntax "${SCRIPT_DIR}/utilities/unlock_admin.sh"
}

@test "8.1.0: utilities/unlock_admin.sh invokes unlock_admin.php" {
    assert_script_contains "${SCRIPT_DIR}/utilities/unlock_admin.sh" 'unlock_admin.php'
}

@test "8.1.0: upgrade scripts exist and have valid syntax" {
    for i in 1 2 3 4 5 6 7 8 9; do
        assert_script_syntax "${SCRIPT_DIR}/upgrade/fsupgrade-${i}.sh"
    done
}

@test "8.1.0: upgrade scripts have priorOpenemrVersion or echo Start" {
    # At least one upgrade script should indicate version upgrade
    local found
    found=$(grep -l 'priorOpenemrVersion\|echo "Start: Upgrade' "${SCRIPT_DIR}"/upgrade/fsupgrade-*.sh 2>/dev/null | head -1)
    [[ -n "$found" ]]
}

@test "8.1.0: devtoolsLibrary.source exists" {
    assert_file_exists "${SCRIPT_DIR}/utilities/devtoolsLibrary.source"
}
