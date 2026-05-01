#!/usr/bin/env bash
# Verify contents:write by creating $BRANCH from default and committing a stub file.
# Requires env: GH_TOKEN, OWNER, REPO_NAME, BRANCH, RUN_ID.

set -euo pipefail

main() {
    : "${OWNER:?OWNER is required}" "${REPO_NAME:?REPO_NAME is required}"
    : "${BRANCH:?BRANCH is required}" "${RUN_ID:?RUN_ID is required}"
    local default_branch base_sha stub_b64
    default_branch=$(gh api "/repos/${OWNER}/${REPO_NAME}" --jq '.default_branch')
    base_sha=$(gh api "/repos/${OWNER}/${REPO_NAME}/git/ref/heads/${default_branch}" --jq '.object.sha')
    if ! gh api -X POST "/repos/${OWNER}/${REPO_NAME}/git/refs" \
            -f "ref=refs/heads/${BRANCH}" -f "sha=${base_sha}" >/dev/null; then
        printf '::error::release App lacks contents:write (branch create failed)\n'
        exit 1
    fi
    stub_b64=$(printf 'permissions-check %s\n' "${RUN_ID}" | base64)
    if ! gh api -X PUT "/repos/${OWNER}/${REPO_NAME}/contents/.permissions-check-${RUN_ID}" \
            -f "message=permissions-check ${RUN_ID}" \
            -f "content=${stub_b64}" \
            -f "branch=${BRANCH}" >/dev/null; then
        printf '::error::release App lacks contents:write (commit failed)\n'
        exit 1
    fi
}

main "$@"
