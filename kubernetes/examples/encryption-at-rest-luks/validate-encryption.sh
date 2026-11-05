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
if [ -z "$OPENEMR_POD" ]; then
  echo "ERROR: no openemr pod found"
  exit 1
fi

# Write the marker into a test file under /sites/. The openemr container
# sees the decrypted ext4 filesystem at this path.
kubectl exec "$OPENEMR_POD" -c openemr -- sh -c \
  "echo '$MARKER' > /var/www/localhost/htdocs/openemr/sites/encryption-test.txt"

echo "Marker written: $MARKER"
echo

echo "=== Step 2: Read-back through the decrypted mount (should see plaintext) ==="
SEEN_DECRYPTED=$(kubectl exec "$OPENEMR_POD" -c openemr -- cat \
  /var/www/localhost/htdocs/openemr/sites/encryption-test.txt)
echo "Read back via decrypted mount: $SEEN_DECRYPTED"
if [ "$SEEN_DECRYPTED" != "$MARKER" ]; then
  echo "ERROR: round-trip through decrypted mount did not match"
  exit 1
fi
echo

echo "=== Step 3: Grep the raw LUKS blob on NFS for the marker ==="
echo "Launching a short-lived helper pod that mounts websitevolume raw"

# Launch a helper that mounts websitevolume (which contains the LUKS
# container FILE, not the decrypted filesystem) and greps the raw bytes.
# If LUKS is working, the marker must NOT appear.
kubectl run luks-raw-check --rm -i --restart=Never \
  --image=alpine:3.20 \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "luks-raw-check",
      "image": "alpine:3.20",
      "stdin": true,
      "tty": false,
      "command": ["sh", "-c", "grep -a -c '"$MARKER"' /mnt/websitevolume/.openemr-sites.luks || echo 0"],
      "volumeMounts": [{"name": "websitevolume", "mountPath": "/mnt/websitevolume"}]
    }],
    "volumes": [{
      "name": "websitevolume",
      "persistentVolumeClaim": {"claimName": "websitevolume"}
    }]
  }
}' > /tmp/luks-raw-check-output.txt 2>&1 || true

HITS=$(tail -1 /tmp/luks-raw-check-output.txt | tr -d '[:space:]')
echo "Raw-byte matches of marker in LUKS container file: $HITS"
echo

if [ "$HITS" = "0" ]; then
  echo "PASS: plaintext not found in LUKS blob — encryption is effective."
  # Clean up the test file
  kubectl exec "$OPENEMR_POD" -c openemr -- rm \
    /var/www/localhost/htdocs/openemr/sites/encryption-test.txt
  exit 0
else
  echo "FAIL: plaintext WAS found in the LUKS blob ($HITS matches)."
  echo "LUKS encryption is NOT active. Investigate the sidecar logs:"
  echo "  kubectl logs $OPENEMR_POD -c luks-opener"
  exit 1
fi
