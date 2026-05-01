#!/usr/bin/env bash
# Fail if the release App lacks metadata:read on $OWNER/$REPO_NAME.
# Requires env: GH_TOKEN, OWNER, REPO_NAME.

set -euo pipefail

main() {
    : "${OWNER:?OWNER is required}" "${REPO_NAME:?REPO_NAME is required}"
    if ! gh api "/repos/${OWNER}/${REPO_NAME}" --jq '.full_name' >/dev/null; then
        printf '::error::release App lacks metadata:read on %s/%s\n' "${OWNER}" "${REPO_NAME}"
        exit 1
    fi
}

main "$@"
