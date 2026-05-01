#!/usr/bin/env bash
# Best-effort delete the throwaway probe branch. Runs even if earlier probes failed.
# Requires env: GH_TOKEN, OWNER, REPO_NAME, BRANCH.

set -euo pipefail

main() {
    : "${OWNER:?OWNER is required}" "${REPO_NAME:?REPO_NAME is required}" "${BRANCH:?BRANCH is required}"
    gh api -X DELETE "/repos/${OWNER}/${REPO_NAME}/git/refs/heads/${BRANCH}" >/dev/null 2>&1 || true
}

main "$@"
