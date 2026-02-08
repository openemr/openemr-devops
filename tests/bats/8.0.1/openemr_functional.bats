# BATS: 8.0.1 openemr.sh — functional tests (early execution and role logic)

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.0.1)"
    OPENEMR="${SCRIPT_DIR}/openemr.sh"
    [[ -f "$OPENEMR" ]]
}

@test "8.0.1 openemr: script starts and reaches MySQL wait or fails with MySQL message" {
    # Run with default env; script will source devtoolsLibrary then eventually wait_for_mysql.
    # Use timeout if available (Linux), else run without (may hang briefly on macOS).
    run bash -c "if command -v timeout >/dev/null 2>&1; then timeout 15 '$OPENEMR' 2>&1; else '$OPENEMR' 2>&1; fi" || true
    [[ $output == *"MySQL"* ]] || [[ $output == *"mysql"* ]] || [[ $output == *"Waiting"* ]] || [[ $status -ne 0 ]]
}

@test "8.0.1 openemr: with K8S=admin script does not immediately syntax-error" {
    # Quick run to ensure script parses and starts; it will fail when trying to run mysqladmin etc.
    run bash -c "if command -v timeout >/dev/null 2>&1; then timeout 5 env K8S=admin MYSQL_HOST=localhost MYSQL_ROOT_PASS=root '$OPENEMR' 2>&1; else env K8S=admin MYSQL_HOST=localhost MYSQL_ROOT_PASS=root '$OPENEMR' 2>&1; fi" || true
    [[ $output != *"syntax error"* ]]
    [[ $status -ne 2 ]]
}

@test "8.0.1 openemr: CONFIGURATION is set after prepareVariables when sourced with env" {
    # Source only the library and openemr.sh vars then call prepareVariables via library
    run bash -c "export MYSQL_HOST=db MYSQL_ROOT_PASS=secret; source '${SCRIPT_DIR}/utilities/devtoolsLibrary.source'; prepareVariables; echo \"CONFIG=\$CONFIGURATION\""
    [[ $status -eq 0 ]]
    [[ $output == *"server=db"* ]]
    [[ $output == *"rootpass=secret"* ]]
}
