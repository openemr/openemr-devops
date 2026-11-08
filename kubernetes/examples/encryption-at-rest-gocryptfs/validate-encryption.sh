#!/bin/bash
#
# Validation recipe: prove that data written through the openemr pod's
# gocryptfs-decrypted mount is actually encrypted on the NFS backing.
#
# This script runs in CI (post-adoption check in the gocryptfs workflow)
# and is also useful to run interactively against a live cluster after
# applying the gocryptfs example manifests per README.md.
#
# What it demonstrates:
#   1. Write a known plaintext string to a file inside the openemr pod's
#      /var/www/localhost/htdocs/openemr/sites directory (which is the
#      gocryptfs-decrypted view of the backing directory on NFS).
#   2. Read it back via the gocryptfs-mounter sidecar's /mnt/decrypted
#      view — proves the FUSE mount is live and openemr's /sites is
#      actually the gocryptfs mount (and not, e.g., a pod-local emptyDir
#      from a mount-propagation failure).
#   3. Positive proof — gocryptfs.conf exists, parses as JSON, declares
#      a supported AEAD cipher (AES-GCM or AES-GCM-SIV), and the EME
#      filename-encryption feature flag is set.
#   4. Filename-encryption positive proof — known plaintext filenames
#      that openemr creates during boot (sqlconf.php, documents, default)
#      MUST NOT appear in `ls` of the raw backing directory.
#   5. Content leakage negative proof (sampled) — for each encrypted file
#      in the backing directory (there's one backing file per plaintext
#      file, unlike LUKS which is one monolithic blob), head-sample a
#      few MiB and grep for the plaintext marker we just wrote.
#   6. OPTIONAL full-file content scan — if VALIDATE_FULL=1 is set,
#      scan the entire contents of every backing file for the marker.
#      Slower; use for paranoia-level verification.
#
# Expected outcome: PASS at every step.

set -euo pipefail

MARKER="GOCRYPTFS-ENCRYPTION-TEST-MARKER-$(date +%s)"
VALIDATE_FULL="${VALIDATE_FULL:-0}"

echo "=== Step 1: Writing marker string through the decrypted mount ==="
OPENEMR_POD=$(kubectl get pod -l name=openemr -o jsonpath='{.items[0].metadata.name}')
if [[ -z "${OPENEMR_POD}" ]]; then
  echo "ERROR: no openemr pod found"
  exit 1
fi

# Write the marker into a test file under /sites/. The openemr container
# sees the gocryptfs-decrypted view at this path.
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

echo "=== Step 2b: Confirm the marker is on the gocryptfs-mapped filesystem ==="
# Read the marker through the sidecar's view of the decrypted mount. The
# sidecar is where the FUSE mount is live; if /sites in the main container
# is NOT the gocryptfs mount (e.g. mount propagation failed and the main
# container is writing to a pod-local emptyDir), Step 2 round-trips through
# that emptyDir but the sidecar's /mnt/decrypted still has nothing. Reading
# the marker from /mnt/decrypted proves the write actually reached the
# gocryptfs-mapped filesystem.
SEEN_IN_MAPPING=$(kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- cat \
  /mnt/decrypted/encryption-test.txt 2>/dev/null || true)
if [[ "${SEEN_IN_MAPPING}" != "${MARKER}" ]]; then
  echo "ERROR: marker not found on /mnt/decrypted via the gocryptfs-mounter sidecar."
  echo "/sites in the main container may not be the gocryptfs mount — check"
  echo "mount propagation and the sidecar's startupProbe."
  exit 1
fi
echo "Marker visible on /mnt/decrypted via gocryptfs-mounter: mapping is live."
echo

echo "=== Step 3: Positive proof — gocryptfs.conf exists and parses as JSON ==="
# gocryptfs.conf is JSON. Parse it with a minimal awk-level sanity check
# and then with python for structural correctness. We grep out the
# supported-cipher fields and verify EME (filename encryption) is on.
CONF_PATH=/mnt/websitevolume/gocryptfs-backing/gocryptfs.conf
if ! kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- test -f "${CONF_PATH}"; then
  echo "FAIL: ${CONF_PATH} does not exist."
  echo "The sidecar may have skipped init, or the backing dir was replaced."
  exit 1
fi

CONF_JSON=$(kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- cat "${CONF_PATH}")
# Minimal JSON parse — pipe through python since it's the one JSON tool
# we can rely on being available on the GHA runner.
if ! echo "${CONF_JSON}" | python3 -c 'import json, sys; json.load(sys.stdin)'; then
  echo "FAIL: ${CONF_PATH} did not parse as valid JSON."
  echo "${CONF_JSON}"
  exit 1
fi
echo "PASS: gocryptfs.conf exists and parses as JSON."
echo

echo "=== Step 3b: Cipher check — content cipher is AES-GCM or AES-GCM-SIV ==="
# gocryptfs.conf's FeatureFlags list and Version imply the content cipher.
# Modern gocryptfs (v2+) defaults to AES-GCM; older defaults to AES-GCM-SIV.
# The `GCMIV128` flag indicates AES-GCM with 128-bit IVs (current default);
# `AESSIV` indicates the SIV variant.
# Either is an AEAD construction — proves real crypto, not cipher=null.
echo "gocryptfs.conf structural summary (FeatureFlags + Version):"
echo "${CONF_JSON}" | python3 -c '
import json, sys
c = json.load(sys.stdin)
print("Creator:     ", c.get("Creator", "?"))
print("Version:     ", c.get("Version", "?"))
print("FeatureFlags:", c.get("FeatureFlags", []))
'
# Flag set should contain at least one of the recognized content-cipher
# markers. Require one of: GCMIV128 (AES-GCM, modern default), AESSIV
# (AES-GCM-SIV legacy default), XChaCha20Poly1305 (opt-in but still AEAD).
CIPHER_MATCH=$(echo "${CONF_JSON}" | python3 -c '
import json, sys
c = json.load(sys.stdin)
flags = set(c.get("FeatureFlags", []))
for marker in ("GCMIV128", "AESSIV", "XChaCha20Poly1305"):
    if marker in flags:
        print(marker)
        break
')
if [[ -z "${CIPHER_MATCH}" ]]; then
  echo "FAIL: gocryptfs.conf FeatureFlags does not contain a recognized AEAD cipher marker."
  echo "Expected one of: GCMIV128, AESSIV, XChaCha20Poly1305"
  exit 1
fi
echo "PASS: gocryptfs content cipher is ${CIPHER_MATCH}."
echo

echo "=== Step 3c: Filename-encryption feature flag check ==="
# EME is gocryptfs's filename encryption scheme (AES-based wide-block
# cipher). Its presence here is REQUIRED for Step 4's filename-leak
# check to be meaningful. Also check that PlaintextNames is NOT set
# (an opt-in flag that disables filename encryption).
EME_ON=$(echo "${CONF_JSON}" | python3 -c '
import json, sys
c = json.load(sys.stdin)
flags = set(c.get("FeatureFlags", []))
# "EMENames" is the gocryptfs feature flag name; "PlaintextNames"
# would be the opt-out.
if "PlaintextNames" in flags:
    print("plaintext")
elif "EMENames" in flags or "DirIV" in flags:
    # DirIV implies name encryption is on (per-dir IVs for filename AES).
    print("encrypted")
else:
    print("unknown")
')
if [[ "${EME_ON}" != "encrypted" ]]; then
  echo "FAIL: gocryptfs filename encryption is not active (got '${EME_ON}')."
  echo "This example assumes default encrypted filenames; PlaintextNames mode"
  echo "would materially change the filename-leak check below."
  exit 1
fi
echo "PASS: gocryptfs filename encryption is active (EME+DirIV)."
echo

echo "=== Step 4: Filename-encryption positive proof — known plaintext names must NOT appear in raw backing ==="
# Boot-time, OpenEMR creates well-known filenames in sites/ (sqlconf.php,
# documents/, default/, etc.). If filename encryption is working, NONE of
# these should appear in `ls` of the raw backing directory — operators
# browsing the NFS backing see only encrypted-filename blobs like
# `5NOxPYSqKQ4=`.
BACKING_LS=$(kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- \
  ls -A /mnt/websitevolume/gocryptfs-backing/)
echo "Raw backing-dir top-level listing (first 20 entries):"
echo "${BACKING_LS}" | head -20
echo

LEAKED_NAMES=""
for name in sqlconf.php documents default encryption-test.txt; do
  if echo "${BACKING_LS}" | grep -qxF "${name}"; then
    LEAKED_NAMES="${LEAKED_NAMES} ${name}"
  fi
done

if [[ -n "${LEAKED_NAMES}" ]]; then
  echo "FAIL: plaintext filename(s) found in raw backing directory:${LEAKED_NAMES}"
  echo "gocryptfs filename encryption appears NOT to be active."
  exit 1
fi
echo "PASS: no plaintext filenames (sqlconf.php, documents, default, encryption-test.txt) in raw backing."
echo

echo "=== Step 5: Content leakage negative proof (sampled) — no plaintext marker in backing files ==="
# Unlike LUKS (one monolithic container file), gocryptfs stores each
# plaintext file as its own encrypted backing file. So we iterate over
# every regular file in the backing directory (skipping gocryptfs.conf
# itself, which is JSON control metadata) and head-sample each.
#
# Why head-sample rather than full-scan: on NFS with many files this is
# ~seconds rather than ~minutes. Each plaintext file maps to one
# backing file; a broken content cipher that left plaintext in a file
# would leak the marker within the first few KiB of the file matching
# our marker's plaintext source. VALIDATE_FULL=1 below scans every
# byte of every backing file.
#
# Head size: 4 MiB — well above any single plaintext file openemr's
# boot sequence writes (sqlconf.php is ~KB, cached files are <1 MiB).
# The marker itself is short, so an unencrypted write of it would land
# entirely within the first 4 MiB of its backing file.
SAMPLE_BYTES=4194304

RAW_CHECK_OUT=$(mktemp -t gocryptfs-raw-check-output.XXXXXX)
trap 'rm -f "${RAW_CHECK_OUT}"' EXIT

set +e
# shellcheck disable=SC2016
# The $MARKER and $SAMPLE_BYTES expansions inside the sh -c body are
# INTENTIONALLY expanded by the INNER sh (which receives them as
# positional args via `_ "${MARKER}" "${SAMPLE_BYTES}"`), not by the
# outer bash. ShellCheck can't model two-layer shell invocations, so
# it flags the single-quoted body as if the outer bash were supposed
# to expand it.
kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- sh -c '
  set -eu
  MARKER="$1"
  SAMPLE_BYTES="$2"
  BACKING=/mnt/websitevolume/gocryptfs-backing
  # Skip gocryptfs.conf (control metadata, JSON, not ciphertext) and
  # gocryptfs.diriv (per-directory IV files, tiny). Scan everything
  # else — including subdirectories recursively, since each plaintext
  # file at any depth has its own encrypted-filename backing file
  # under a per-dir encrypted-name directory.
  find "$BACKING" -type f \
    ! -name "gocryptfs.conf" \
    ! -name "gocryptfs.diriv" \
    -print |
  while IFS= read -r f; do
    # head -c N is best-effort: if the file is smaller than N, we get
    # the whole file; if larger, we get the first N bytes. grep -c
    # counts matches; -a treats binary as text (we are deliberately
    # grepping ciphertext for a plaintext string that should not be
    # there). Any non-zero count is a leak.
    HITS=$(head -c "$SAMPLE_BYTES" "$f" | grep -a -c -F "$MARKER" 2>/dev/null || true)
    if [ -n "$HITS" ] && [ "$HITS" != "0" ]; then
      echo "LEAK_IN_FILE: $f ($HITS hit(s))"
    fi
  done
  # Re-derive scan count outside the while-subshell. This is also how
  # we distinguish "all clean" from "no files scanned at all" (the
  # latter would be an unexpected empty backing dir and is a FAIL
  # upstairs — see the SCANNED guard after this exec).
  SCANNED_COUNT=$(find "$BACKING" -type f \
    ! -name "gocryptfs.conf" \
    ! -name "gocryptfs.diriv" | wc -l)
  echo "FILES_SCANNED=$SCANNED_COUNT"
' _ "${MARKER}" "${SAMPLE_BYTES}" > "${RAW_CHECK_OUT}" 2>&1
GREP_RC=$?
set -e

echo "scan exit code: ${GREP_RC}"
echo "---BEGIN RAW OUTPUT---"
cat "${RAW_CHECK_OUT}"
echo "---END RAW OUTPUT---"
echo

if [[ "${GREP_RC}" -ne 0 ]]; then
  echo "FAIL: backing-file scan exited non-zero."
  exit 1
fi

if grep -q '^LEAK_IN_FILE:' "${RAW_CHECK_OUT}"; then
  echo "FAIL: plaintext marker found in one or more backing files."
  grep '^LEAK_IN_FILE:' "${RAW_CHECK_OUT}"
  echo "gocryptfs content encryption appears NOT to be active. Investigate:"
  echo "  kubectl logs ${OPENEMR_POD} -c gocryptfs-mounter"
  exit 1
fi

SCANNED=$(grep '^FILES_SCANNED=' "${RAW_CHECK_OUT}" | tail -1 | cut -d= -f2)
if [[ -z "${SCANNED}" ]] || [[ "${SCANNED}" = "0" ]]; then
  echo "FAIL: no backing files were scanned — backing directory appears empty."
  echo "That is unexpected: the marker write should have produced at least one"
  echo "encrypted backing file."
  exit 1
fi
echo "PASS: plaintext marker NOT found in head-sampled (${SAMPLE_BYTES} B) scan of ${SCANNED} backing files."
echo

if [[ "${VALIDATE_FULL}" = "1" ]]; then
  echo "=== Step 5b: Full-content leakage scan (VALIDATE_FULL=1) ==="
  echo "Scanning every byte of every gocryptfs backing file for the marker."
  echo "This reads the whole backing tree over NFS — expect several minutes on"
  echo "a seeded openemr install."

  FULL_CHECK_OUT=$(mktemp -t gocryptfs-full-check-output.XXXXXX)
  trap 'rm -f "${RAW_CHECK_OUT}" "${FULL_CHECK_OUT}"' EXIT

  set +e
  # Same two-layer shell pattern as Step 5: inner single-quoted sh -c
  # body expands $1/$MARKER via positional args passed after `_`.
  # shellcheck disable=SC2016
  kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- sh -c '
    set -eu
    MARKER="$1"
    BACKING=/mnt/websitevolume/gocryptfs-backing
    find "$BACKING" -type f \
      ! -name "gocryptfs.conf" \
      ! -name "gocryptfs.diriv" \
      -print |
    while IFS= read -r f; do
      HITS=$(grep -a -c -F "$MARKER" "$f" 2>/dev/null || true)
      if [ "$HITS" != "0" ] && [ -n "$HITS" ]; then
        echo "LEAK_IN_FILE: $f ($HITS hit(s))"
      fi
    done
    SCANNED_COUNT=$(find "$BACKING" -type f \
      ! -name "gocryptfs.conf" \
      ! -name "gocryptfs.diriv" | wc -l)
    echo "FILES_SCANNED=$SCANNED_COUNT"
  ' _ "${MARKER}" > "${FULL_CHECK_OUT}" 2>&1
  FULL_RC=$?
  set -e

  echo "full-scan exit code: ${FULL_RC}"
  echo "---BEGIN FULL RAW OUTPUT---"
  cat "${FULL_CHECK_OUT}"
  echo "---END FULL RAW OUTPUT---"
  echo

  if [[ "${FULL_RC}" -ne 0 ]]; then
    echo "FAIL: full backing-file scan exited non-zero."
    exit 1
  fi
  if grep -q '^LEAK_IN_FILE:' "${FULL_CHECK_OUT}"; then
    echo "FAIL: plaintext marker found in one or more backing files on full scan."
    grep '^LEAK_IN_FILE:' "${FULL_CHECK_OUT}"
    exit 1
  fi
  FULL_SCANNED=$(grep '^FILES_SCANNED=' "${FULL_CHECK_OUT}" | tail -1 | cut -d= -f2)
  echo "PASS: plaintext marker NOT found in full scan of ${FULL_SCANNED} backing files."
  echo
fi

echo "ALL CHECKS PASSED: gocryptfs encryption is effective."
# Clean up the test file.
kubectl exec "${OPENEMR_POD}" -c openemr -- rm \
  /var/www/localhost/htdocs/openemr/sites/encryption-test.txt
exit 0
