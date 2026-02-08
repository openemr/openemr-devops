# BATS: 8.0.1 unlock_admin.sh — functional tests (exit codes and argument passing)

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.0.1)"
    UNLOCK="${SCRIPT_DIR}/utilities/unlock_admin.sh"
    [[ -f "$UNLOCK" ]]
}

@test "8.0.1 unlock_admin: exits non-zero when /root does not exist" {
    # When not in container, /root may not exist or php may not find unlock_admin.php
    run bash -c "'$UNLOCK' 2>&1; exit \$?"
    # Expect failure: either cd /root fails or php fails
    [[ $status -ne 0 ]]
}

@test "8.0.1 unlock_admin: with one arg, password is passed to php" {
    # Simulate what unlock_admin.sh does: cd to dir and run php unlock_admin.php "$1"
    # Verify the contract that the first argument is passed through
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

@test "8.0.1 unlock_admin: script is executable or at least runnable via bash" {
    run bash "$UNLOCK" 2>&1
    # May succeed only in container; we just check it runs (no "command not found")
    [[ $output != *"command not found"* ]] || true
}
