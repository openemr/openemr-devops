#!/usr/bin/env bash
# Fail if the release App is not installed on $OWNER/$REPO_NAME.
# Requires env: GH_TOKEN, OWNER, REPO_NAME.

set -euo pipefail

main() {
    : "${OWNER:?OWNER is required}" "${REPO_NAME:?REPO_NAME is required}"
    local repos
    repos=$(gh api /installation/repositories --paginate --jq '.repositories[].full_name')
    if ! grep -Fxq "${OWNER}/${REPO_NAME}" <<< "${repos}"; then
        printf '::error::release App is not installed on %s/%s\n' "${OWNER}" "${REPO_NAME}"
        exit 1
    fi
}

main "$@"
