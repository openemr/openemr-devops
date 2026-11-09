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

STAMP="$(date +%s)-$$"
MARKER="GOCRYPTFS-ENCRYPTION-TEST-MARKER-${STAMP}"
# Unique marker file per run. Sites-visible filename includes the run
# stamp so overlapping invocations do not overwrite each other's
# markers, and so a crashed prior run cannot leave a stale
# encryption-test.txt that this run would blindly overwrite and then
# delete (destroying any operator data that happened to share that name).
MARKER_FILENAME="encryption-test-${STAMP}.txt"
MARKER_SITES_PATH="/var/www/localhost/htdocs/openemr/sites/${MARKER_FILENAME}"
MARKER_DECRYPTED_PATH="/mnt/decrypted/${MARKER_FILENAME}"
VALIDATE_FULL="${VALIDATE_FULL:-0}"

# Best-effort cleanup on any exit path so a crashed run does not leave
# its marker behind, and so any tempfiles the sampled/full-scan steps
# create are swept up. Separate arrays rather than a stack of overlapping
# traps so a later `trap '...' EXIT` cannot clobber the marker cleanup.
declare -a CLEANUP_TMPFILES=()
# shellcheck disable=SC2329,SC2317  # function + body invoked indirectly via `trap ... EXIT`
cleanup_all() {
  rc=$?
  if [[ -n "${OPENEMR_POD:-}" ]]; then
    kubectl exec "${OPENEMR_POD}" -c openemr -- rm -f "${MARKER_SITES_PATH}" \
      >/dev/null 2>&1 || true
  fi
  if [[ "${#CLEANUP_TMPFILES[@]}" -gt 0 ]]; then
    rm -f "${CLEANUP_TMPFILES[@]}" || true
  fi
  return "${rc}"
}
trap cleanup_all EXIT

echo "=== Step 1: Writing marker string through the decrypted mount ==="
OPENEMR_POD=$(kubectl get pod -l name=openemr -o jsonpath='{.items[0].metadata.name}')
if [[ -z "${OPENEMR_POD}" ]]; then
  echo "ERROR: no openemr pod found"
  exit 1
fi

# Write the marker into a unique test file under /sites/. The openemr
# container sees the gocryptfs-decrypted view at this path.
kubectl exec "${OPENEMR_POD}" -c openemr -- sh -c \
  "echo '${MARKER}' > ${MARKER_SITES_PATH}"

echo "Marker written: ${MARKER}"
echo "Marker file:    ${MARKER_SITES_PATH}"
echo

echo "=== Step 2: Read-back through the decrypted mount (should see plaintext) ==="
SEEN_DECRYPTED=$(kubectl exec "${OPENEMR_POD}" -c openemr -- cat \
  "${MARKER_SITES_PATH}")
echo "Read back via decrypted mount: ${SEEN_DECRYPTED}"
if [[ "${SEEN_DECRYPTED}" != "${MARKER}" ]]; then
  echo "ERROR: round-trip through decrypted mount did not match"
  exit 1
fi
echo

echo "=== Step 2a: Verify the live gocryptfs mount in the sidecar ==="
# Before trusting Step 2b's marker-visibility check, confirm the
# sidecar's /mnt/decrypted is REALLY a live fuse / fuse.gocryptfs
# mount. If gocryptfs silently fell back to writing into the emptyDir,
# or if the emptyDir itself got unmounted and only the sidecar's view
# of a plain tmpfs/ext4 path remains, the Step 2b marker-visible check
# would pass vacuously (both views see the raw emptyDir) while the
# content-leakage checks (Step 5) pass against older/empty backing
# files and the whole script reports PASS on unencrypted storage.
# Fail hard here instead.
# shellcheck disable=SC2016  # the $2/$3 inside single quotes are awk fields, not shell variables
#
# NOTE: do NOT `exit` on the first match. The kubelet bind-mounts an
# emptyDir at /mnt/decrypted BEFORE the sidecar's gocryptfs process
# runs — so /proc/mounts can contain two entries at this path, with
# the emptyDir listed first (older in the mount table) and the FUSE
# overmount listed later. The EFFECTIVE mount at that path is the
# last entry; taking the first would reject a healthy FUSE-overmounted
# setup. The sidecar's own final-verification path (in the Deployment
# manifest) uses the same `tail -1` pattern for the same reason.
MOUNT_FS_LINE=$(kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- \
  awk '$2 == "/mnt/decrypted" { print $3 }' /proc/mounts 2>/dev/null \
  | tail -1 || true)
echo "Sidecar /proc/mounts fs-type for /mnt/decrypted: '${MOUNT_FS_LINE}'"
case "${MOUNT_FS_LINE}" in
  fuse|fuse.gocryptfs)
    echo "PASS: sidecar /mnt/decrypted is a live FUSE mount."
    ;;
  *)
    echo "FAIL: sidecar /mnt/decrypted is NOT a FUSE mount."
    echo "This means Step 2b's marker visibility (if it passes) would be"
    echo "testing the underlying emptyDir, not the gocryptfs-mapped"
    echo "filesystem. Investigate:"
    echo "  kubectl logs ${OPENEMR_POD} -c gocryptfs-mounter"
    exit 1
    ;;
esac
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
  "${MARKER_DECRYPTED_PATH}" 2>/dev/null || true)
if [[ "${SEEN_IN_MAPPING}" != "${MARKER}" ]]; then
  echo "ERROR: marker not found on /mnt/decrypted via the gocryptfs-mounter sidecar."
  echo "/sites in the main container may not be the gocryptfs mount — check"
  echo "mount propagation and the sidecar's startupProbe."
  exit 1
fi
echo "Marker visible on /mnt/decrypted via gocryptfs-mounter: mapping is live."
echo

echo "=== Step 2c: Verify the main container's Apache worker UID can read the mount ==="
# The sidecar runs gocryptfs as root. Without -allow_other the FUSE
# mount is restricted to root, and the main container's non-root
# Apache worker gets EACCES on /sites — the main container's root
# probes pass but the actual request-serving user cannot read site
# config or uploaded documents. Confirm the apache httpd user can
# read the marker we just wrote.
APACHE_UID=$(kubectl exec "${OPENEMR_POD}" -c openemr -- \
  sh -c 'id -u apache 2>/dev/null || getent passwd apache | cut -d: -f3' 2>/dev/null \
  | tr -d '[:space:]' || true)
if [[ -z "${APACHE_UID}" ]]; then
  echo "WARN: could not resolve 'apache' UID in main container; skipping worker-UID read check."
else
  SEEN_AS_APACHE=$(kubectl exec "${OPENEMR_POD}" -c openemr -- \
    su -s /bin/sh apache -c "cat ${MARKER_SITES_PATH}" 2>/dev/null || true)
  if [[ "${SEEN_AS_APACHE}" != "${MARKER}" ]]; then
    echo "FAIL: Apache worker (uid=${APACHE_UID}) cannot read the FUSE mount."
    echo "The gocryptfs sidecar may be missing -allow_other, or /etc/fuse.conf"
    echo "may not have user_allow_other enabled. Without this, the main"
    echo "container works for root probes but fails for actual HTTP traffic."
    exit 1
  fi
  echo "PASS: Apache worker (uid=${APACHE_UID}) can read the FUSE mount."
fi
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
for name in sqlconf.php documents default "${MARKER_FILENAME}"; do
  if echo "${BACKING_LS}" | grep -qxF "${name}"; then
    LEAKED_NAMES="${LEAKED_NAMES} ${name}"
  fi
done

if [[ -n "${LEAKED_NAMES}" ]]; then
  echo "FAIL: plaintext filename(s) found in raw backing directory:${LEAKED_NAMES}"
  echo "gocryptfs filename encryption appears NOT to be active."
  exit 1
fi
echo "PASS: no plaintext filenames (sqlconf.php, documents, default, ${MARKER_FILENAME}) in raw backing."
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
CLEANUP_TMPFILES+=("${RAW_CHECK_OUT}")

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
  #
  # Traversal failures: `find ... -print` writes an entry per file to
  # stdout and writes any permission/IO error to stderr. If the whole
  # find fails we bail here, which propagates through `set -e`. In the
  # middle of the while-loop, we track SCANNED_OK (only incremented
  # when the per-file head+grep pipeline succeeded end-to-end) and
  # SCAN_ERRORS separately so the upstairs check can distinguish
  # "scanned 42, all clean" from "scanned 42, but 7 errors along the
  # way — cannot trust the clean verdict".
  SCANNED_OK=0
  SCAN_ERRORS=0
  TMPLIST=$(mktemp)
  # Capture find stderr separately so we can surface traversal errors.
  if ! find "$BACKING" -type f \
      ! -name "gocryptfs.conf" \
      ! -name "gocryptfs.diriv" \
      -print > "$TMPLIST" 2>&1; then
    echo "FIND_FAILED: $(cat "$TMPLIST")"
    exit 2
  fi
  while IFS= read -r f; do
    # head -c N on a regular file: if the file is smaller than N we
    # get the whole file; if larger, we get the first N bytes. Both
    # paths return success. A head FAILURE (unreadable file / NFS I/O
    # error) is counted as a scan error rather than silently treated
    # as "no hits".
    if HEAD_OUT=$(head -c "$SAMPLE_BYTES" "$f" 2>/dev/null); then
      HITS=$(printf "%s" "$HEAD_OUT" | grep -a -c -F "$MARKER" 2>/dev/null || true)
      if [ -n "$HITS" ] && [ "$HITS" != "0" ]; then
        echo "LEAK_IN_FILE: $f ($HITS hit(s))"
      fi
      SCANNED_OK=$((SCANNED_OK + 1))
    else
      echo "SCAN_ERROR: head failed on $f"
      SCAN_ERRORS=$((SCAN_ERRORS + 1))
    fi
  done < "$TMPLIST"
  # Total files find saw (so we can compare against SCANNED_OK).
  TOTAL=$(wc -l < "$TMPLIST" | tr -d "[:space:]")
  rm -f "$TMPLIST"
  echo "FILES_SCANNED=$SCANNED_OK"
  echo "FILES_FOUND=$TOTAL"
  echo "SCAN_ERRORS=$SCAN_ERRORS"
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

if grep -q '^FIND_FAILED:' "${RAW_CHECK_OUT}"; then
  echo "FAIL: find failed to walk the backing directory. Treat as incomplete scan."
  exit 1
fi

SCANNED=$(grep '^FILES_SCANNED=' "${RAW_CHECK_OUT}" | tail -1 | cut -d= -f2)
FOUND=$(grep '^FILES_FOUND=' "${RAW_CHECK_OUT}" | tail -1 | cut -d= -f2)
ERRORS=$(grep '^SCAN_ERRORS=' "${RAW_CHECK_OUT}" | tail -1 | cut -d= -f2)

if [[ -z "${SCANNED}" ]] || [[ -z "${FOUND}" ]] || [[ -z "${ERRORS}" ]]; then
  echo "FAIL: could not parse scan tally from sidecar output."
  exit 1
fi

if [[ "${ERRORS}" != "0" ]]; then
  echo "FAIL: ${ERRORS} backing file(s) could not be scanned (head/IO errors)."
  echo "A clean no-leak verdict requires every file to actually be read."
  grep '^SCAN_ERROR:' "${RAW_CHECK_OUT}" || true
  exit 1
fi

if [[ "${SCANNED}" != "${FOUND}" ]]; then
  echo "FAIL: scan tally mismatch — find listed ${FOUND} files but only ${SCANNED} were scanned."
  exit 1
fi

# Minimum backing-file floor. A gocryptfs-initialized backing dir with
# any content at all has at minimum:
#   - the marker file (1)
#   - sqlconf.php / documents/ / default/ / cache seed, etc. (several)
# Even a bare-bones init with just our one write produces several
# backing files because openemr's boot writes sqlconf.php + leader-
# election marker + session-scratch. An unexpected tally of fewer than
# 3 means either find pointed at the wrong dir or the migration
# didn't land. Fail rather than PASS on a shallow scan.
MIN_FILES=3
if [[ "${SCANNED}" -lt "${MIN_FILES}" ]]; then
  echo "FAIL: only ${SCANNED} backing file(s) scanned (floor ${MIN_FILES})."
  echo "The marker write and the openemr boot should have produced more."
  echo "Likely cause: find ran against an empty or wrong directory."
  exit 1
fi
echo "PASS: plaintext marker NOT found in head-sampled (${SAMPLE_BYTES} B) scan of ${SCANNED} backing files (0 errors)."
echo

if [[ "${VALIDATE_FULL}" = "1" ]]; then
  echo "=== Step 5b: Full-content leakage scan (VALIDATE_FULL=1) ==="
  echo "Scanning every byte of every gocryptfs backing file for the marker."
  echo "This reads the whole backing tree over NFS — expect several minutes on"
  echo "a seeded openemr install."

  FULL_CHECK_OUT=$(mktemp -t gocryptfs-full-check-output.XXXXXX)
  CLEANUP_TMPFILES+=("${FULL_CHECK_OUT}")

  set +e
  # Same two-layer shell pattern as Step 5: inner single-quoted sh -c
  # body expands $1/$MARKER via positional args passed after `_`.
  # shellcheck disable=SC2016
  kubectl exec "${OPENEMR_POD}" -c gocryptfs-mounter -- sh -c '
    set -eu
    MARKER="$1"
    BACKING=/mnt/websitevolume/gocryptfs-backing
    SCANNED_OK=0
    SCAN_ERRORS=0
    TMPLIST=$(mktemp)
    if ! find "$BACKING" -type f \
        ! -name "gocryptfs.conf" \
        ! -name "gocryptfs.diriv" \
        -print > "$TMPLIST" 2>&1; then
      echo "FIND_FAILED: $(cat "$TMPLIST")"
      exit 2
    fi
    while IFS= read -r f; do
      # grep -a reads the whole file; any read error (I/O, permission)
      # makes grep exit non-zero. We treat non-zero-on-no-match (exit
      # 1) as "no hits" and anything else as a scan error.
      #
      # IMPORTANT: this inner sh runs with set -eu. A bare
      # HITS=$(grep ...) would see grep exit 1 on no-match and errexit
      # out of the inner shell BEFORE we could inspect $?, so the
      # full-scan step would FAIL on clean storage. Guard the
      # assignment with || GREP_RC=$? so the status is captured and
      # errexit does not fire. Matches the shape the LUKS sibling
      # validate-encryption.sh uses for the same reason.
      GREP_RC=0
      HITS=$(grep -a -c -F "$MARKER" "$f" 2>/dev/null) || GREP_RC=$?
      case "$GREP_RC" in
        0|1)
          if [ "$GREP_RC" = "0" ] && [ -n "$HITS" ] && [ "$HITS" != "0" ]; then
            echo "LEAK_IN_FILE: $f ($HITS hit(s))"
          fi
          SCANNED_OK=$((SCANNED_OK + 1))
          ;;
        *)
          echo "SCAN_ERROR: grep exited $GREP_RC on $f"
          SCAN_ERRORS=$((SCAN_ERRORS + 1))
          ;;
      esac
    done < "$TMPLIST"
    TOTAL=$(wc -l < "$TMPLIST" | tr -d "[:space:]")
    rm -f "$TMPLIST"
    echo "FILES_SCANNED=$SCANNED_OK"
    echo "FILES_FOUND=$TOTAL"
    echo "SCAN_ERRORS=$SCAN_ERRORS"
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
  if grep -q '^FIND_FAILED:' "${FULL_CHECK_OUT}"; then
    echo "FAIL: find failed to walk the backing directory in full-scan mode."
    exit 1
  fi
  FULL_SCANNED=$(grep '^FILES_SCANNED=' "${FULL_CHECK_OUT}" | tail -1 | cut -d= -f2)
  FULL_FOUND=$(grep '^FILES_FOUND=' "${FULL_CHECK_OUT}" | tail -1 | cut -d= -f2)
  FULL_ERRORS=$(grep '^SCAN_ERRORS=' "${FULL_CHECK_OUT}" | tail -1 | cut -d= -f2)
  if [[ -z "${FULL_SCANNED}" ]] || [[ -z "${FULL_FOUND}" ]] || [[ -z "${FULL_ERRORS}" ]]; then
    echo "FAIL: could not parse full-scan tally from sidecar output."
    exit 1
  fi
  if [[ "${FULL_ERRORS}" != "0" ]]; then
    echo "FAIL: ${FULL_ERRORS} backing file(s) could not be scanned in full-scan mode."
    grep '^SCAN_ERROR:' "${FULL_CHECK_OUT}" || true
    exit 1
  fi
  if [[ "${FULL_SCANNED}" != "${FULL_FOUND}" ]]; then
    echo "FAIL: full-scan tally mismatch — find listed ${FULL_FOUND} files but only ${FULL_SCANNED} were scanned."
    exit 1
  fi
  if [[ "${FULL_SCANNED}" -lt "${MIN_FILES}" ]]; then
    echo "FAIL: only ${FULL_SCANNED} backing file(s) scanned in full-scan mode (floor ${MIN_FILES})."
    exit 1
  fi
  echo "PASS: plaintext marker NOT found in full scan of ${FULL_SCANNED} backing files (0 errors)."
  echo
fi

echo "ALL CHECKS PASSED: gocryptfs encryption is effective."
# Marker cleanup runs via the EXIT trap (cleanup_marker). Explicit
# rm here removed to avoid double-cleanup and to keep cleanup
# idempotent on early-exit paths.
exit 0
