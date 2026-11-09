# BATS: assert the macOS leg actually runs under Apple's system bash 3.2.
#
# openemr-cmd is a host CLI that developers run on their Macs. The macOS
# leg of this workflow exists specifically to exercise bash 3.2
# compatibility, because Apple hasn't updated /bin/bash past 3.2.57
# since 2007 (GPLv3). PR #785 added the leg after the BSD-realpath
# fallout in #783, and the leg immediately paid for itself by surfacing
# two real bash-4-isms (${var,,} case-modification, and `source <(cmd)`
# process substitution silently defining no functions under 3.2).
#
# If bats' `#!/usr/bin/env bash` shebang ever resolves to a newer
# Homebrew bash on the runner (bash 4/5 lives at
# /opt/homebrew/bin/bash or /usr/local/bin/bash and can sneak ahead of
# /bin/bash on PATH), the leg silently stops delivering its coverage
# while still passing. This test turns that silent regression into a
# loud failure.
#
# The test skips on non-macOS legs — the coverage intent is specific to
# Apple's shipped bash. Linux legs run whatever the image ships.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

@test "macOS leg runs under Apple system bash 3.2 (portability coverage)" {
    [[ "$OSTYPE" == darwin* ]] || skip "non-macOS leg; bash-3.2 coverage does not apply"

    local major="${BASH_VERSINFO[0]:-?}"
    local minor="${BASH_VERSINFO[1]:-?}"

    if [[ "$major" != 3 || "$minor" != 2 ]]; then
        echo "Expected Apple's system bash 3.2.* (the coverage intent of this leg)."
        echo "Actual: BASH_VERSION=$BASH_VERSION (major=$major minor=$minor)"
        echo
        echo "A newer bash (likely Homebrew) resolved ahead of /bin/bash in bats'"
        echo "#!/usr/bin/env bash shebang. Either point bats at /bin/bash"
        echo "explicitly, or drop the Homebrew bash prefix from PATH for the"
        echo "bats step. See #785 for the rationale."
        false
    fi
}
