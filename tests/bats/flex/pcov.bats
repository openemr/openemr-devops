# BATS: flex pcov.sh — PCOV coverage

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir flex)"
    [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR" ]]
}

@test "flex pcov.sh: PCOV_ON check" {
    assert_script_contains "${SCRIPT_DIR}/pcov.sh" 'PCOV_ON'
}

@test "flex pcov.sh: php-pcov-configured marker" {
    assert_script_contains "${SCRIPT_DIR}/pcov.sh" 'php-pcov-configured'
}

@test "flex pcov.sh: pecl-pcov and zend_extension config" {
    assert_script_contains "${SCRIPT_DIR}/pcov.sh" 'pecl-pcov'
    assert_script_contains "${SCRIPT_DIR}/pcov.sh" 'zend_extension='
    assert_script_contains "${SCRIPT_DIR}/pcov.sh" 'pcov.enabled=1'
}

@test "flex pcov.sh: pcov.directory openemr" {
    assert_script_contains "${SCRIPT_DIR}/pcov.sh" 'pcov.directory'
}
