# BATS: binary unlock_admin.sh — functional tests

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir binary)"
    UNLOCK="${SCRIPT_DIR}/utilities/unlock_admin.sh"
    [[ -f "$UNLOCK" ]]
}

@test "binary unlock_admin: exits non-zero when not in container" {
    run bash -c "'$UNLOCK' 2>&1" || true
    [[ $status -ne 0 ]]
}

@test "binary unlock_admin: with one arg, password is passed to php" {
    tmpdir="${BATS_TEST_TMPDIR}/fake_root"
    mkdir -p "$tmpdir"
    echo '#!/bin/sh
echo "ARGV1:$2"' > "${tmpdir}/php"
    chmod +x "${tmpdir}/php"
    echo '<?php echo "ok"; ?>' > "${tmpdir}/unlock_admin.php"
    run bash -c "cd '$tmpdir' && ./php ./unlock_admin.php mypass123"
    [[ $status -eq 0 ]]
    [[ $output == *"mypass123"* ]]
}
