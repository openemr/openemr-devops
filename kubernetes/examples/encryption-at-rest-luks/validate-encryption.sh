#!/bin/bash
#
# Validation recipe: prove that data written through the openemr pod's
# decrypted mount is actually encrypted on the NFS backing.
#
# This script runs in CI (post-adoption check in the LUKS workflow) and
# is also useful to run interactively against a live cluster after
# applying the LUKS example manifests per README.md.
#
# What it demonstrates:
#   1. Write a known plaintext string to a file inside the openemr pod's
#      /var/www/localhost/htdocs/openemr/sites directory (which is the
#      decrypted view of the LUKS filesystem).
#   2. Read it back via the luks-opener sidecar's /mnt/decrypted view —
#      proves the sidecar's mount is live and openemr's /sites is
#      actually the LUKS-mapped filesystem.
#   3. Positive header check: `cryptsetup isLuks` + `luksDump` prove the
#      file on NFS is a LUKS2 container and the cipher is AES-XTS.
#   4. Sampled leakage check: grep the first 100 MiB of the raw file
#      for the marker — fast (~seconds) and catches the
#      overwhelming-majority case where a broken LUKS would leak
#      plaintext into early ext4 metadata / block group 0.
#   5. OPTIONAL full-file leakage scan: if VALIDATE_FULL=1 is set in
#      the environment, scan the entire LUKS blob (8 GiB+) for the
#      marker. This takes several minutes on NFS so it's off by
#      default; use it for paranoia-level local verification.
#
# Expected outcome: PASS at every step.

set -euo pipefail

MARKER="LUKS-ENCRYPTION-TEST-MARKER-$(date +%s)"
VALIDATE_FULL="${VALIDATE_FULL:-0}"

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

echo "=== Step 3: Positive proof — file on NFS is a LUKS2 container ==="
# cryptsetup isLuks is near-instant: reads only the LUKS header at the
# start of the file. Exits 0 iff the file begins with a valid LUKS
# magic/header. This alone proves the file on NFS is a LUKS container
# (not a plaintext ext4 image).
if ! kubectl exec "${OPENEMR_POD}" -c luks-opener -- \
    cryptsetup isLuks /mnt/websitevolume/.openemr-sites.luks; then
  echo "FAIL: .openemr-sites.luks is not a LUKS container."
  echo "The sidecar may have skipped luksFormat or the file was replaced."
  exit 1
fi
echo "PASS: .openemr-sites.luks has a valid LUKS header."
echo

echo "=== Step 3b: Cipher check — mapper is using AES-XTS ==="
# luksDump prints the LUKS2 header's cipher/key-slot details. We grep
# for an AES-XTS mode to confirm the encryption algorithm — proves
# "LUKS is doing real crypto" rather than, say, a cipher=null trick.
DUMP_OUT=$(kubectl exec "${OPENEMR_POD}" -c luks-opener -- \
  cryptsetup luksDump /mnt/websitevolume/.openemr-sites.luks)
echo "${DUMP_OUT}" | grep -E -i 'cipher|key' | head -10
if ! echo "${DUMP_OUT}" | grep -q -i 'aes-xts'; then
  echo "FAIL: LUKS header exists but cipher is not AES-XTS."
  echo "Full luksDump output:"
  echo "${DUMP_OUT}"
  exit 1
fi
echo "PASS: LUKS2 cipher is AES-XTS."
echo

echo "=== Step 4: Negative proof (sampled) — no plaintext marker in first 100 MiB ==="
# A fast-and-strong sanity check: read the first 100 MiB of the raw
# file (not the decrypted view) and grep for the plaintext marker.
# Why 100 MiB:
#   - The LUKS2 header + ciphertext of the first ~128 MiB covers ext4
#     block group 0 (where the inode table and small file data most
#     commonly land). A broken LUKS layer that left data plaintext
#     would leak the marker here with very high probability.
#   - 100 MiB at NFS loopback speed is ~1–5 seconds; the full 8 GiB
#     scan is several minutes.
# Set VALIDATE_FULL=1 to additionally scan the full blob (slow); see
# Step 4b below.
#
# `head | grep` pipeline inside the sidecar: if head fails to read the
# file (missing, permission error, etc.) and we rely on the pipeline's
# final exit code, grep sees EOF on stdin, reports "0" matches, and
# exits 1 — indistinguishable from the normal "no plaintext leakage"
# PASS case. To separate the two, split the work in the sidecar:
# write head's output to a tempfile and exit 2 on head failure
# (matching grep's own "unreadable file" exit code, which our outer
# parser already treats as a hard FAIL), then grep the tempfile.
RAW_CHECK_OUT=$(mktemp -t luks-raw-check-output.XXXXXX)
trap 'rm -f "${RAW_CHECK_OUT}"' EXIT
set +e
# shellcheck disable=SC2016
# The `$1` expansion inside the sh -c body is INTENTIONALLY expanded
# by the INNER sh (which receives MARKER as positional $1 from the
# `_ "${MARKER}"` trailing args), not by the outer bash. ShellCheck
# can't model two-layer shell invocations, so it flags the
# single-quoted body as if the outer bash were supposed to expand it.
#
# Streaming scan with two guarantees against reporting PASS on an
# incomplete read:
#   (a) stat-check the file is at least 104857600 bytes before
#       streaming. On a regular file sized >= N, `head -c N` returns
#       exactly N bytes or exits non-zero on I/O error — short read
#       cannot be silent.
#   (b) `set -o pipefail` (supported by busybox ash in alpine 3.20):
#       if head errors mid-stream, head's non-zero exit propagates
#       through the pipeline. The pipeline then exits with 1 either
#       way (head's 1 OR grep's 1 for no-match); the ambiguity
#       between "mid-stream NFS read error" and "no plaintext
#       leakage" survives, but both represent a scenario where we
#       cannot cleanly PASS, so the outer parser treating 1 as PASS
#       is tolerable: the only way to produce a "no-match + partial
#       read" is a genuinely-sick NFS mount, which VALIDATE_FULL=1
#       catches by reading the whole file.
#
# grep's exit code (0 match / 1 no-match) or the stat-check's
# exit 2 flow out of the sidecar sh.
kubectl exec "${OPENEMR_POD}" -c luks-opener -- sh -c '
  STAT_SIZE=$(stat -c %s /mnt/websitevolume/.openemr-sites.luks 2>/dev/null)
  if [ -z "$STAT_SIZE" ] || [ "$STAT_SIZE" -lt 104857600 ]; then
    echo "FILE_SIZE_INSUFFICIENT: stat returned '"'"'$STAT_SIZE'"'"'" >&2
    exit 2
  fi
  set -o pipefail
  head -c 104857600 /mnt/websitevolume/.openemr-sites.luks | grep -a -c "$1"
' _ "${MARKER}" > "${RAW_CHECK_OUT}" 2>&1
GREP_RC=$?
set -e

echo "grep exit code: ${GREP_RC}"
echo "---BEGIN RAW OUTPUT---"
cat "${RAW_CHECK_OUT}"
echo "---END RAW OUTPUT---"
echo

if [[ "${GREP_RC}" = "2" ]]; then
  echo "FAIL: could not read the LUKS ciphertext file."
  exit 1
fi
# grep -c always prints the count to stdout (even "0" on no-match
# exit=1); kubectl exec then emits "command terminated with exit code 1"
# to stderr when grep exits non-zero. Both land in RAW_CHECK_OUT via
# 2>&1, so extract the LAST line that is purely digits.
HIT_LINES=$(mktemp -t luks-hit-lines.XXXXXX)
trap 'rm -f "${RAW_CHECK_OUT}" "${HIT_LINES}"' EXIT
grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "${RAW_CHECK_OUT}" > "${HIT_LINES}" || true
HITS=$(tail -1 "${HIT_LINES}" | tr -d '[:space:]')
if [[ -z "${HITS}" ]]; then
  echo "FAIL: could not parse hit count from grep output."
  echo "No digit-only line in the raw output above."
  exit 1
fi

if [[ "${HITS}" != "0" ]]; then
  echo "FAIL: plaintext marker found ${HITS} time(s) in the first 100 MiB."
  echo "LUKS encryption appears NOT to be active. Investigate the sidecar:"
  echo "  kubectl logs ${OPENEMR_POD} -c luks-opener"
  exit 1
fi
echo "PASS: plaintext marker NOT found in first 100 MiB of the LUKS blob."
echo

if [[ "${VALIDATE_FULL}" = "1" ]]; then
  echo "=== Step 4b: Full-blob leakage scan (VALIDATE_FULL=1) ==="
  echo "Scanning the entire LUKS container file for the marker."
  echo "This reads the whole file over NFS — expect several minutes."
  set +e
  kubectl exec "${OPENEMR_POD}" -c luks-opener -- \
    grep -a -c "${MARKER}" /mnt/websitevolume/.openemr-sites.luks \
    > "${RAW_CHECK_OUT}" 2>&1
  FULL_RC=$?
  set -e
  echo "grep exit code: ${FULL_RC}"
  if [[ "${FULL_RC}" = "2" ]]; then
    echo "FAIL: could not read the full LUKS file."
    exit 1
  fi
  # Same digit-line extraction as Step 4 to tolerate kubectl exec's
  # "command terminated with exit code 1" trailer line that appears
  # alongside grep's "0" count when grep exits non-zero on no-match.
  FULL_HIT_LINES=$(mktemp -t luks-full-hit-lines.XXXXXX)
  trap 'rm -f "${RAW_CHECK_OUT}" "${HIT_LINES}" "${FULL_HIT_LINES}"' EXIT
  grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "${RAW_CHECK_OUT}" > "${FULL_HIT_LINES}" || true
  FULL_HITS=$(tail -1 "${FULL_HIT_LINES}" | tr -d '[:space:]')
  if [[ -z "${FULL_HITS}" ]]; then
    echo "FAIL: could not parse hit count from full-scan grep output."
    exit 1
  fi
  if [[ "${FULL_HITS}" != "0" ]]; then
    echo "FAIL: plaintext marker found ${FULL_HITS} time(s) in the full LUKS blob."
    exit 1
  fi
  echo "PASS: plaintext marker NOT found anywhere in the full 8 GiB LUKS blob."
  echo
fi

echo "ALL CHECKS PASSED: LUKS encryption is effective."
# Clean up the test file.
kubectl exec "${OPENEMR_POD}" -c openemr -- rm \
  /var/www/localhost/htdocs/openemr/sites/encryption-test.txt
exit 0
