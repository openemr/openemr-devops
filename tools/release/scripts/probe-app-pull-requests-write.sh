#!/usr/bin/env bash
# Verify pull-requests:write by opening a draft PR from $BRANCH and closing it.
# Requires env: GH_TOKEN, OWNER, REPO_NAME, BRANCH, RUN_ID.

set -euo pipefail

main() {
    : "${OWNER:?OWNER is required}" "${REPO_NAME:?REPO_NAME is required}"
    : "${BRANCH:?BRANCH is required}" "${RUN_ID:?RUN_ID is required}"
    local default_branch pr_number
    default_branch=$(gh api "/repos/${OWNER}/${REPO_NAME}" --jq '.default_branch')
    pr_number=$(gh api -X POST "/repos/${OWNER}/${REPO_NAME}/pulls" \
            -f "title=permissions-check ${RUN_ID}" \
            -f "body=Probe run ${RUN_ID}; auto-closed by release-permissions-check workflow." \
            -f "head=${BRANCH}" -f "base=${default_branch}" \
            -F draft=true --jq '.number' || true)
    if [[ -z ${pr_number} ]]; then
        printf '::error::release App lacks pull-requests:write (draft PR open failed)\n'
        exit 1
    fi
    if ! gh api -X PATCH "/repos/${OWNER}/${REPO_NAME}/pulls/${pr_number}" \
            -f 'state=closed' >/dev/null; then
        printf '::error::release App can open but not close PRs\n'
        exit 1
    fi
}

main "$@"
