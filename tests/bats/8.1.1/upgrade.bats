# BATS: 8.1.1 upgrade scripts — structure and consistency

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.1.1)"
    [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR" ]]
    UPGRADE_DIR="${SCRIPT_DIR}/upgrade"
}

@test "8.1.1 upgrade: docker-version file exists and is numeric" {
    assert_file_exists "${UPGRADE_DIR}/docker-version"
    run cat "${UPGRADE_DIR}/docker-version"
    [[ $output =~ ^[0-9]+$ ]]
}

@test "8.1.1 upgrade: fsupgrade-1 through fsupgrade-9 exist" {
    for i in 1 2 3 4 5 6 7 8 9; do
        assert_file_exists "${UPGRADE_DIR}/fsupgrade-${i}.sh"
    done
}

@test "8.1.1 upgrade: each fsupgrade has priorOpenemrVersion or echo Start" {
    for i in 1 2 3 4 5 6 7 8 9; do
        f="${UPGRADE_DIR}/fsupgrade-${i}.sh"
        grep -qE 'priorOpenemrVersion=|echo "Start: Upgrade' "$f" || {
            echo "fsupgrade-${i}.sh missing version/start marker"
            return 1
        }
    done
}

@test "8.1.1 upgrade: each fsupgrade iterates sites" {
    for i in 1 2 3 4 5 6 7 8 9; do
        assert_script_contains "${UPGRADE_DIR}/fsupgrade-${i}.sh" 'sites/\*/'
    done
}

@test "8.1.1 upgrade: fsupgrade-1 ensures documents subdirs" {
    assert_script_contains "${UPGRADE_DIR}/fsupgrade-1.sh" 'documents/'
    assert_script_contains "${UPGRADE_DIR}/fsupgrade-1.sh" 'mkdir -p'
}

@test "8.1.1 upgrade: at least one upgrade runs chown apache" {
    found=0
    for i in 1 2 3 4 5 6 7 8 9; do
        grep -q 'chown.*apache' "${UPGRADE_DIR}/fsupgrade-${i}.sh" && found=1 && break
    done
    [[ $found -eq 1 ]]
}

@test "8.1.1 upgrade: fsupgrade-2 runs sql_upgrade" {
    assert_script_contains "${UPGRADE_DIR}/fsupgrade-2.sh" 'sql_upgrade'
}

@test "8.1.1 upgrade: each script has Completed or echo Completed" {
    for i in 1 2 3 4 5 6 7 8 9; do
        grep -qE 'Completed|echo.*Completed' "${UPGRADE_DIR}/fsupgrade-${i}.sh" || {
            echo "fsupgrade-${i}.sh missing completion marker"
            return 1
        }
    done
}

@test "8.1.1 upgrade: scripts use bash or sh" {
    for i in 1 2 3 4 5 6 7 8 9; do
        head -1 "${UPGRADE_DIR}/fsupgrade-${i}.sh" | grep -qE '^#!(/usr/bin/env |/bin/)(bash|sh)'
    done
}
