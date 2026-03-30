# BATS: 8.1.0 config files — Dockerfile, Apache, PHP

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.1.0)"
    [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR" ]]
}

@test "8.1.0 Dockerfile: FROM alpine" {
    assert_file_contains "${SCRIPT_DIR}/Dockerfile" 'FROM alpine'
}

@test "8.1.0 Dockerfile: PHP and Apache" {
    assert_file_contains "${SCRIPT_DIR}/Dockerfile" 'php'
    assert_file_contains "${SCRIPT_DIR}/Dockerfile" 'apache'
}

@test "8.1.0 Dockerfile: openemr.sh as entrypoint or CMD" {
    assert_file_contains "${SCRIPT_DIR}/Dockerfile" 'openemr.sh'
}

@test "8.1.0 openemr.conf: LoadModule rewrite" {
    assert_file_contains "${SCRIPT_DIR}/openemr.conf" 'LoadModule'
    assert_file_contains "${SCRIPT_DIR}/openemr.conf" 'rewrite'
}

@test "8.1.0 openemr.conf: security or ServerTokens" {
    assert_file_contains "${SCRIPT_DIR}/openemr.conf" 'ServerTokens\|ServerSignature\|Security'
}

@test "8.1.0 php.ini: exists" {
    assert_file_exists "${SCRIPT_DIR}/php.ini"
}

@test "8.1.0 upgrade/docker-version: single positive integer" {
    assert_file_exists "${SCRIPT_DIR}/upgrade/docker-version"
    run cat "${SCRIPT_DIR}/upgrade/docker-version"
    [[ $output =~ ^[0-9]+$ ]]
    [[ $output -ge 1 ]]
}

@test "8.1.0 auto_configure.php: exists" {
    assert_file_exists "${SCRIPT_DIR}/auto_configure.php"
}
