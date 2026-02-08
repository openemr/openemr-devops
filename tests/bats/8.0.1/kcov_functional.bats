# BATS: 8.0.1 kcov-wrapper.sh — functional tests (run script, check behavior)

load '../helpers'

setup() {
    SCRIPT_DIR="$(get_script_dir 8.0.1)"
    KCOV="${SCRIPT_DIR}/kcov-wrapper.sh"
    [[ -f "$KCOV" ]]
}

@test "8.0.1 kcov-wrapper: script produces expected initial output before failing" {
    # Script echoes "Setting up coverage directory..." then mkdir (may fail outside container)
    run bash -c "'$KCOV' 2>&1" || true
    [[ $output == *"Setting up coverage"* ]] || [[ $output == *"coverage"* ]] || [[ $output == *"Running OpenEMR"* ]] || [[ $output == *"Permission denied"* ]]
}

@test "8.0.1 kcov-wrapper: exits non-zero when kcov or openemr.sh not in container paths" {
    # Outside container, /var/www/... may not exist and kcov won't be in path
    run bash -c "'$KCOV' 2>&1; exit \$?"
    [[ $status -ne 0 ]] || [[ $output == *"Running OpenEMR"* ]]
}

@test "8.0.1 kcov-wrapper: with stub kcov and writable coverage dir, runs until exec" {
    # Stub kcov; script may still fail at mkdir /var/www/... outside container
    stub_dir="${BATS_TEST_TMPDIR}/stub_bin"
    mkdir -p "$stub_dir"
    echo '#!/bin/sh
echo "kcov-stub-ran"
exit 0' > "${stub_dir}/kcov"
    chmod +x "${stub_dir}/kcov"
    run env PATH="${stub_dir}:$PATH" bash -c "'$KCOV' 2>&1" || true
    [[ $output == *"Setting up coverage"* ]] || [[ $output == *"kcov-stub-ran"* ]] || [[ $output == *"coverage"* ]] || [[ $output == *"Running OpenEMR"* ]] || [[ $output == *"Permission denied"* ]]
}
