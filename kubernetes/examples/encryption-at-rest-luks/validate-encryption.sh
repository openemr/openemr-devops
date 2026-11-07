#!/bin/bash
#
# Validation recipe: prove that data written through the openemr pod's
# decrypted mount is actually encrypted on the NFS backing.
#
# This is a RECIPE, not a CI test. It assumes a running cluster that has
# applied the LUKS example manifests per README.md. Run interactively and
# read the output.
#
# What it demonstrates:
#   1. Write a known plaintext string to a file inside the openemr pod's
#      /var/www/localhost/htdocs/openemr/sites directory (which is the
#      decrypted view of the LUKS filesystem).
#   2. Read the raw bytes of the LUKS container file from a privileged
#      helper pod that mounts websitevolume directly (without opening LUKS).
#   3. Grep for the plaintext string in the raw LUKS blob — it MUST NOT
#      be found. If it is, LUKS is misconfigured.
#
# Expected outcome: step 3 prints "PASS: plaintext not found in LUKS blob".

set -euo pipefail

MARKER="LUKS-ENCRYPTION-TEST-MARKER-$(date +%s)"

echo "=== Step 1: Writing marker string through the decrypted mount ==="
OPENEMR_POD=$(kubectl get pod -l name=openemr -o jsonpath='{.items[0].metadata.name}')
if [[ -z "${OPENEMR_POD}" ]]; then
  echo "ERROR: no openemr pod found"
  exit 1
fi

# Write the marker into a test file under /sites/. The openemr container
# sees the decrypted ext4 filesystem at this path.
kubectl exec "${OPENEMR_POD}" -c openemr -- sh -c \
  "echo '${MARKER}' > /var/www/localhost/htdocs/openemr/sites/encryption-test.txt"

echo "Marker written: ${MARKER}"
echo

echo "=== Step 2: Read-back through the decrypted mount (should see plaintext) ==="
SEEN_DECRYPTED=$(kubectl exec "${OPENEMR_POD}" -c openemr -- cat \
  /var/www/localhost/htdocs/openemr/sites/encryption-test.txt)
echo "Read back via decrypted mount: ${SEEN_DECRYPTED}"
if [[ "${SEEN_DECRYPTED}" != "${MARKER}" ]]; then
  echo "ERROR: round-trip through decrypted mount did not match"
  exit 1
fi
echo

echo "=== Step 2b: Confirm the marker is on the LUKS-mapped filesystem ==="
# Read the marker through the sidecar's view of the decrypted mount. The
# sidecar is where the LUKS mapping is live; if /sites in the main container
# is NOT the LUKS mapping (e.g. mount propagation failed and the main
# container is writing to a pod-local emptyDir), Step 2 round-trips through
# that emptyDir but the sidecar's /mnt/decrypted still has nothing. Reading
# the marker from /mnt/decrypted proves the write actually reached the
# LUKS-mapped filesystem.
SEEN_IN_MAPPING=$(kubectl exec "${OPENEMR_POD}" -c luks-opener -- cat \
  /mnt/decrypted/encryption-test.txt 2>/dev/null || true)
if [[ "${SEEN_IN_MAPPING}" != "${MARKER}" ]]; then
  echo "ERROR: marker not found on /mnt/decrypted via the luks-opener sidecar."
  echo "/sites in the main container may not be the LUKS mapping — check"
  echo "mount propagation and the sidecar's startupProbe."
  exit 1
fi
echo "Marker visible on /mnt/decrypted via luks-opener: mapping is live."
echo

echo "=== Step 3: Grep the raw LUKS blob on NFS for the marker ==="
echo "Running grep inside the existing luks-opener sidecar (which already has"
echo "websitevolume mounted) — no new helper pod to attach + pull."

# Use mktemp so a predictable path cannot be used to follow a symlink and
# truncate an unintended file on a shared host. Clean up on exit.
RAW_CHECK_OUT=$(mktemp -t luks-raw-check-output.XXXXXX)
trap 'rm -f "${RAW_CHECK_OUT}"' EXIT

# Why kubectl exec into the sidecar, not a new kubectl-run helper pod:
# the sidecar already has `websitevolume` bind-mounted at
# /mnt/websitevolume (it's where it reads .openemr-sites.luks to open
# the mapper). Running grep there is a per-process operation inside an
# already-running container — no extra pod to schedule, no second
# ReadWriteMany attach, no alpine image pull, no `kubectl run -i`
# 60-second wait-for-Ready timeout window. The ciphertext view at
# /mnt/websitevolume/.openemr-sites.luks is what we want to scan: it's
# the raw LUKS blob on NFS (not the decrypted view the sidecar also
# mounts at /mnt/decrypted).
#
# Exit codes of `grep -c`: 0 if N matches (N printed to stdout),
#                          1 if no match ("0" printed to stdout),
#                          2 if the file is unreadable.
# We treat 0 and 1 as "parse the printed count"; 2 as a hard FAIL.
set +e
kubectl exec "${OPENEMR_POD}" -c luks-opener -- \
  grep -a -c "${MARKER}" /mnt/websitevolume/.openemr-sites.luks \
  > "${RAW_CHECK_OUT}" 2>&1
GREP_RC=$?
set -e

echo "grep exit code: ${GREP_RC}"
echo "---BEGIN RAW OUTPUT---"
cat "${RAW_CHECK_OUT}"
echo "---END RAW OUTPUT---"
echo

if [[ "${GREP_RC}" = "2" ]]; then
  echo "ERROR: grep could not read the LUKS ciphertext file."
  echo "This usually means .openemr-sites.luks is missing or unreadable"
  echo "from the luks-opener sidecar's view of websitevolume."
  exit 1
fi
if [[ "${GREP_RC}" != "0" && "${GREP_RC}" != "1" ]]; then
  echo "ERROR: unexpected grep exit code ${GREP_RC} (kubectl exec or"
  echo "the sidecar container itself may have failed)."
  exit 1
fi

# Parse the digit-only line grep -c emits. Done as two steps (not a
# pipeline inside $(...)) because `set -o pipefail` combined with
# grep's exit-1-on-no-match can cause the whole pipeline to count as a
# script failure.
HIT_LINES=$(mktemp -t luks-hit-lines.XXXXXX)
trap 'rm -f "${RAW_CHECK_OUT}" "${HIT_LINES}"' EXIT
grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "${RAW_CHECK_OUT}" > "${HIT_LINES}" || true
HITS=$(tail -1 "${HIT_LINES}" | tr -d '[:space:]')
if [[ -z "${HITS}" ]]; then
  echo "ERROR: could not parse hit count from grep output."
  echo "No digit-only lines were found — see raw output above."
  exit 1
fi
echo "Raw-byte matches of marker in LUKS container file: ${HITS}"
echo

if [[ "${HITS}" = "0" ]]; then
  echo "PASS: plaintext not found in LUKS blob — encryption is effective."
  # Clean up the test file
  kubectl exec "${OPENEMR_POD}" -c openemr -- rm \
    /var/www/localhost/htdocs/openemr/sites/encryption-test.txt
  exit 0
else
  echo "FAIL: plaintext WAS found in the LUKS blob (${HITS} matches)."
  echo "LUKS encryption is NOT active. Investigate the sidecar logs:"
  echo "  kubectl logs ${OPENEMR_POD} -c luks-opener"
  exit 1
fi
