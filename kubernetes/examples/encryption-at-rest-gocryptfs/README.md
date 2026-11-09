# In-pod gocryptfs encryption-at-rest over NFS (multi-replica)

This directory is an **example**, not a default. It demonstrates a variant of Option 2 of the two encryption-at-rest patterns outlined in `kubernetes/README.md` § **Production Hardening → Encryption at rest (storage layer)**:

- **Option 1 (default stack recommendation):** back the NFS server's PVC with an encrypted StorageClass (cloud KMS, Longhorn, Rook/Ceph). Simple, transparent, zero application change. Keys live with the storage layer / cloud KMS.
- **Option 2a — LUKS (`examples/encryption-at-rest-luks/`):** the openemr pod wraps `websitevolume` in a LUKS container file. Strongest metadata hiding (NFS sees one opaque blob). **Single-replica only** — LUKS wraps a single ext4 filesystem that cannot be multi-writer.
- **Option 2b — gocryptfs, this example:** the openemr pod transparently encrypts each file individually via gocryptfs in `-sharedstorage` mode. **Multi-replica (default `replicas: 3`) retained, rollout strategy upgraded from the default stack's `Recreate` to `RollingUpdate`.** Trade-off: NFS sees per-file ciphertext blobs with encrypted filenames, not one monolithic opaque blob — directory structure cardinality leaks (number of files, their rough sizes) even though filenames and contents are encrypted.

**Do not adopt this example unless you have a specific threat model that requires it.** Option 1 covers the overwhelming majority of HIPAA at-rest requirements with far less operational complexity. This example exists for users whose threat model treats the NFS server pod (or the storage layer under it) as untrusted AND who cannot accept the single-replica downgrade that the LUKS sibling example imposes.

## When to use this (vs LUKS vs Option 1)

Pick **this example (Option 2b, gocryptfs)** when **all** of the following apply:

- You cannot trust the operator of the backing storage (third-party NFS appliance, shared storage cluster, multi-tenant storage) to never read the on-disk blocks.
- You need **multi-replica openemr** (availability model depends on 2+ replicas, or you want zero-downtime rolling updates).
- You can accept that an attacker with NFS-backing read access sees per-file ciphertext with encrypted filenames (cardinality + rough-size metadata leaks) rather than one opaque LUKS blob.

Pick **Option 2a (LUKS)** when:

- You need maximum metadata hiding (NFS sees one file; counts, sizes, access patterns per-file are hidden).
- Single-replica openemr is acceptable (or you are running small enough that you were going to do that anyway).

Pick **Option 1 (encrypted StorageClass)** when:

- You are on a hyperscaler and trust the cloud KMS / encrypted-disk model.
- You do not need defense against a compromised NFS server pod.
- You want the simplest operational model.

## Trade-offs: Option 1 vs 2a (LUKS) vs 2b (gocryptfs, this example)

| Axis | Option 1 (encrypted StorageClass) | Option 2a (LUKS) | Option 2b (gocryptfs, **this example**) |
|---|---|---|---|
| **Where encryption happens** | Storage layer (below NFS server pod) | Application pod (inside LUKS container file) | Application pod (FUSE, per-file) |
| **NFS server pod sees** | Plaintext | One opaque LUKS container file | Per-file ciphertext + encrypted filenames |
| **Replicas supported** | Any | **1** | **Any** (default 3; `-sharedstorage` mode) |
| **Rolling updates** | Yes | No (Recreate) | **Yes** (RollingUpdate; upgraded from the default stack's Recreate) |
| **Metadata leaked to NFS** | File tree, names, sizes, access times | None (single opaque file) | File count, per-file ciphertext sizes (filenames are encrypted) |
| **Privilege required** | None beyond default | Privileged sidecar | Privileged sidecar (FUSE needs `/dev/fuse` + `CAP_SYS_ADMIN`) |
| **Operational complexity** | Low | Medium | Medium |
| **Protects against stolen disks** | Yes | Yes | Yes |
| **Protects against snapshot exfil** | Yes | Yes | Yes |
| **Protects against compromised NFS server pod** | No | **Yes** (sees only opaque blob) | **Yes** (sees only ciphertext + encrypted names; cardinality/size metadata still visible) |
| **Protects against compromised openemr pod** | No | No | No |
| **Backup compatibility** | Standard | LUKS file as opaque blob + passphrase for restore | Backing-dir tree + passphrase for restore; tools that walk the tree see encrypted filenames (opaque but traversable) |
| **Key rotation** | Storage layer / cloud KMS native | `cryptsetup luksAddKey`/`luksRemoveKey` | `gocryptfs -passwd` against the backing dir |

Options 1 and 2 are not mutually exclusive — running both as defense-in-depth is valid.

## Concurrent-writer semantics (why multi-replica works here)

LUKS wraps a single ext4 filesystem that cannot be opened read-write by two pods simultaneously. gocryptfs is structurally different: it encrypts each plaintext file to a separate ciphertext file in the backing directory. There is no shared filesystem journal to coordinate — every FUSE write is a write to a specific backing file.

The `-sharedstorage` mount option disables gocryptfs's own metadata caching so that when pod A writes a new file, pod B sees the new backing-file entry on its next readdir rather than a stale cached view. It is REQUIRED for correctness when multiple pods mount the same backing directory. This example sets it.

**Visibility latency is bounded by the underlying NFS cache, not instant.** `-sharedstorage` closes the gocryptfs-internal cache window, but the backing filesystem (NFS, over the stunnel tunnel in the #910 stack) imposes its own kernel dentry-cache + attribute-cache window on top. The ceiling is the mount's `actimeo` value: the #910 stack pins `actimeo=0` on the openemr `websitevolume` mount, which makes cross-pod visibility effectively immediate — no attribute caching, every readdir re-fetches from the NFS server. On any other NFS configuration (different `actimeo`, a pNFS backend, a non-NFS shared filesystem), the bound shifts accordingly: visibility is "stale by up to `actimeo` seconds", not "instant". If you adapt this example to a backing store with a larger attribute-cache window, writes from pod A are still durable and correct — but pod B may not see them for up to that window. Size your application-level coordination around that bound.

**What is safe:**

- Concurrent writes to **different** files from different replicas (the normal OpenEMR workload — per-upload unique filenames, per-replica temp files, per-session scratch). gocryptfs's per-file independent ciphertext makes this safe at the storage layer. The `-sharedstorage` flag ensures cross-pod directory visibility.
- Concurrent reads of the same file from different replicas.

**What is NOT safe without application-level coordination:**

- Concurrent writes to the **same** file from multiple replicas. gocryptfs does not provide cross-pod file locking. If two replicas truly need to coordinate same-file writes, OpenEMR (or the operator) must provide that coordination — same as on any POSIX-RWX shared filesystem. In practice, OpenEMR does not have this pattern at the `sites/` layer: session state lives in Redis, per-request temp files use unique names, and document uploads use unique paths. The one caveat worth calling out is first-boot leader election via the shared sites volume (see `startupProbe` comment in the default `deployment.yaml`): this is the only place OpenEMR writes a specific well-known marker path from multiple replicas on startup. The existing election logic already handles the "another leader got there first" race by checking before writing and is tested on multi-replica NFS; it works the same way on gocryptfs-over-NFS.
- A replica reading a file that another replica is **actively overwriting**. gocryptfs rewrites a file as a sequence of fixed-size encrypted blocks on the backing store. A reader whose read lands between the writer's block-level flushes can land in either of two bad outcomes:
  1. **Mixed-but-valid blocks (no error).** The read returns one block of the OLD ciphertext followed by one block of the NEW ciphertext. Each block authenticates as valid on its own — gocryptfs's per-block AEAD tag covers only that block's plaintext + block-index + file-id, not cross-block ordering — so the reader sees a seamless response code-path-wise but the byte sequence is nonsensical as application data. The read call does NOT return an error.
  2. **Torn block (`EIO`).** The read lands in the middle of a specific block the writer is partway through flushing. The partial ciphertext fails per-block authentication and gocryptfs surfaces that as an I/O error to the reader.
  Which outcome you get depends on alignment between the writer's flush boundaries and the reader's request offsets, and is not predictable. This is correctness-by-design behavior (an authenticated-encryption filesystem cannot fabricate a consistent view across a concurrent overwrite), but the first outcome is the dangerous one: callers that assume "read succeeded → bytes are coherent" see garbage without any error signal. **If a consistent view matters, coordinate readers and writers at the application layer.** The standard pattern — write to a temp file and `rename()` into place — moves the concurrency boundary to the directory level where it is atomic, and is what OpenEMR's upload path already does. The caveat applies to any custom code or module that rewrites files in place without a rename-based swap.

If your OpenEMR deployment adds a feature that concurrent-writes a shared `sites/` path from multiple replicas without coordination, that feature is already broken on the default NFS stack, not just this example — the fix belongs in OpenEMR core, not here.

## Operational hardening (production prerequisite)

The manifests ship with `apk add --no-cache gocryptfs fuse3` at container start in both the `gocryptfs-mounter` sidecar (`openemr-deployment-gocryptfs.yaml`) and the one-shot init Job (`gocryptfs-init-job.yaml`). This is deliberate for an example — the manifests are self-contained and copy-pasteable against a stock `alpine:3.24` image — but it has two production-visible costs:

1. **Startup latency and Alpine-repository dependency on every pod start.** Each new sidecar start re-downloads the packages from Alpine's repositories. A cluster that cannot reach `dl-cdn.alpinelinux.org` (air-gapped, egress-firewalled) cannot start the gocryptfs sidecar, so the openemr pod never becomes ready.
2. **Unpinned package versions.** `apk add` resolves whatever the Alpine repo currently serves, which drifts over time and can be yanked. A repro-build guarantee requires pinning the tools.

**Before adopting this example in production**, bake a pinned image that already contains `gocryptfs` and `fuse3`:

```dockerfile
FROM alpine:3.24
RUN apk add --no-cache gocryptfs fuse3
```

Push it to your own registry, pin by digest, and point BOTH the `gocryptfs-mounter` sidecar's `image:` field AND the init Job's `image:` field at that pinned digest. Then strip the `apk add` line from both container command scripts. Using the same image for both keeps the tool versions in lockstep between init time and mount time (gocryptfs's on-disk format is backward-compatible across minor versions, but matching versions avoids surprises).

## Privilege / capability requirements

- **`gocryptfs-init-job.yaml`** — runs once per deployment lifetime. Does **NOT** require privileged: true. The init step only writes two regular files (`gocryptfs.conf`, `gocryptfs.diriv`) into a regular directory — no FUSE mount, no loop device, no kernel-level work. This is a meaningful operational advantage over the LUKS example's one-shot format Job.
- **`openemr-deployment-gocryptfs.yaml`** — adds a `gocryptfs-mounter` **sidecar** with `privileged: true`. The sidecar performs the FUSE mount via `gocryptfs -sharedstorage`. FUSE mounting requires `/dev/fuse` access and `CAP_SYS_ADMIN`, which in practice means `privileged: true` on most clusters. It uses `mountPropagation: Bidirectional` so its mount reaches the host mount namespace.
- **The main `openemr` container is NOT privileged.** It mounts the shared `emptyDir` with `mountPropagation: HostToContainer`, so it inherits the sidecar's mount transparently without needing any elevated capability itself.

**Cluster prerequisites:**

- Nodes must have the FUSE kernel module available (standard on all modern Linux distros; present on Kind's default `kindest/node` image).
- The kubelet must allow privileged containers. This is the default; some hardened clusters disable it via PodSecurity admission — the gocryptfs example will not deploy there without an exception.
- PodSecurity admission: the namespace running this example needs to permit privileged containers (the `gocryptfs-mounter` sidecar sets `privileged: true`). Under PodSecurity Standards, only the `privileged` level allows that — `baseline` and `restricted` both reject privileged pods when **enforced**. PodSecurity Admission does *not* support per-pod exemption by label; the supported options are: (1) run the example in a namespace whose `pod-security.kubernetes.io/enforce` label is `privileged`; (2) have the cluster admin configure a PodSecurity-exempt `RuntimeClass` in the admission configuration file and set `runtimeClassName:` on these pods; or (3) leave enforcement off for the namespace (warn/audit only) and accept the warnings. The right option depends on your cluster's security posture — per-namespace is usually the simplest.

## Key management

This example uses a Kubernetes Secret (`gocryptfs-passphrase-secret.yaml`) with a placeholder passphrase. This is DEVELOPMENT ONLY — the passphrase in the file is publicly visible in this repo.

For production, treat the gocryptfs passphrase as a top-tier secret (loss = permanent data loss, exposure = encryption bypass) and upgrade the Secret to an external secret manager via **External Secrets Operator (ESO)**:

- **HashiCorp Vault:** `ExternalSecret` referencing a Vault KV path; ESO materializes the Kubernetes Secret.
- **AWS Secrets Manager:** `ExternalSecret` with IRSA-backed `SecretStore` to the secret ARN.
- **GCP Secret Manager:** `ExternalSecret` with Workload Identity to the secret resource.
- **Azure Key Vault:** `ExternalSecret` with Managed Identity to the secret.

In all four cases, the downstream manifests (`openemr-deployment-gocryptfs.yaml`, `gocryptfs-init-job.yaml`) consume the resulting Kubernetes Secret unchanged.

**Rotation is NOT as simple as rotating the Kubernetes Secret.** gocryptfs's master key is wrapped by a scrypt-derived KEK of the passphrase and stored in `gocryptfs.conf`. The sidecar reads the Secret only at pod start, and `gocryptfs` consults `gocryptfs.conf`, not the Secret, to unwrap the master key. Updating the Secret alone leaves the old passphrase as the only working key.

The correct rotation sequence is:

1. Change the wrapped passphrase in `gocryptfs.conf` by running `gocryptfs -passwd` against the backing directory. Run this from a short-lived helper pod that mounts `websitevolume`, with the OLD passphrase available via `-passfile` on a transient secret:

   ```bash
   gocryptfs -passwd /mnt/websitevolume/gocryptfs-backing
   # interactively enter the OLD passphrase, then the NEW one twice
   ```

   (For automation, gocryptfs also accepts `-masterkey=<hex>` on mount to bypass the passphrase path entirely — useful if you have escrowed the raw master key. To export the master key for escrow, use `gocryptfs-xray -dumpmasterkey` against the backing dir's `gocryptfs.conf`; it prompts for the current passphrase and prints the hex master key. Store that value in your KMS alongside the passphrase. Note that neither `gocryptfs -info` nor `-masterkey stdin` exports the key — `-info` only prints structural metadata, and `-masterkey` is a mount-time import flag.)

2. Update the Kubernetes Secret (`gocryptfs-passphrase`) to the NEW passphrase. If you are using ESO, rotate the upstream secret and let ESO materialize.

3. Trigger a rolling restart of the openemr pods (`kubectl rollout restart deployment openemr`). Each new pod's sidecar re-reads the Secret and `gocryptfs` unwraps the master key with the NEW passphrase (which `gocryptfs.conf` now accepts).

Unlike LUKS, there is no concept of "key slots" in gocryptfs.conf — it stores a single wrapped master key. Rotation is atomic: after `gocryptfs -passwd` succeeds, the OLD passphrase no longer works. Any pod that has not yet been restarted and is still holding its FUSE mount open continues to serve traffic (the master key is in memory), but a fresh pod started with the OLD passphrase will fail to mount. Plan the rolling restart to begin immediately after the `-passwd` step.

**What `gocryptfs -passwd` does NOT rotate.** The command rewraps the master key with a new KEK derived from the NEW passphrase. **The master key itself does not change.** Consequently, anyone who ever held BOTH the OLD passphrase AND a copy of the pre-rotation `gocryptfs.conf` (e.g. an operator who ran `gocryptfs-xray -dumpmasterkey` with the OLD passphrase, or a backup of the old `gocryptfs.conf` combined with the old passphrase) can still derive the master key and decrypt every file that was written under this backing — including files written AFTER the rotation, because they were encrypted with the same unchanged master key. Passphrase rotation closes the "someone who only has the passphrase but not the config" attack vector, not the "someone who had both at some point" vector.

If the threat model requires rotating the master key itself (e.g. known or suspected master-key compromise), passphrase rotation is NOT sufficient. The correct procedure is to migrate to a fresh backing directory:

1. Scale openemr to 0 (same quiescence procedure as adoption/rollback).
2. Run a one-off `gocryptfs -init` against a new backing directory with a NEW passphrase — this generates a brand-new master key.
3. Mount both the OLD and NEW decrypted views in a helper pod, rsync OLD → NEW, verify (file counts + checksum sample, same shape as adoption's step 3b).
4. Swap the Deployment to point at the NEW backing directory and the NEW passphrase Secret.
5. Decommission the OLD backing directory per your organization's data-destruction policy (overwrite, cryptographic erase of the holding storage, etc.). Simply deleting the files leaves ciphertext blocks on the NFS backend that remain decryptable if the OLD master key is compromised.

**Hardware KMS integration** (CloudHSM, AWS KMS envelope encryption of the gocryptfs passphrase itself) is the next tier up and out of scope for this example.

**Passphrase loss is irrecoverable.** gocryptfs has no escrow and no backdoor. Back the passphrase up in your organization's password escrow / KMS BEFORE running `gocryptfs-init-job.yaml`.

## Persistence semantics

- **The gocryptfs backing directory** (`gocryptfs-backing/` inside the NFS-backed `websitevolume`) is the durable artifact. It contains `gocryptfs.conf`, per-directory `gocryptfs.diriv` files, and one encrypted-filename ciphertext file per plaintext file. It survives pod restarts, deployment rollouts, and cluster reboots as long as the PVC persists.
- **The FUSE mount at `/mnt/decrypted`** (per pod) and the sidecar's `gocryptfs` process are ephemeral. The sidecar re-establishes them on every pod start by running `gocryptfs -sharedstorage` against the backing directory. Nothing FUSE-related survives a pod delete — which is correct, because the pod's view is the decrypted plaintext and that must not persist outside the pod.
- **The decrypted view** (`emptyDir`-backed shared mountpoint) is per-pod and per-replica. When a pod is deleted, Kubernetes wipes the `emptyDir`; the kernel FUSE mapping stops existing on that node; and the only surviving artifact is the gocryptfs backing directory on NFS, which is ciphertext.

## Step-by-step adoption

Two paths are supported:

- **Migration from a running default-stack deployment** — openemr has already run first-boot on plaintext NFS; migrate the existing site contents into a newly-initialized gocryptfs backing. Simplest flow; the one the CI workflow exercises. **Caveat:** first-boot wrote `sqlconf.php` (containing the DB password) and the initial GACL rows to plaintext NFS. For deployments where even a historical plaintext snapshot of those credentials is disqualifying, use the greenfield path below.
- **Greenfield adoption (no plaintext first-boot)** — the encrypted backing is initialized BEFORE openemr first-boot runs, so `sqlconf.php` and the demo seed land inside the gocryptfs mount from the beginning. More operationally tight (relies on racing kubelet to delete the default openemr Deployment before its pods boot) and gated by a defensive check that falls back to the migration path if that race is lost.

### Migration from a running default-stack deployment

Starting from a running #910 default stack:

```bash
# 0. Prerequisites: #910 default stack is up AND openemr has completed
#    first-boot. Verify:
kubectl get deployment openemr
kubectl get pvc websitevolume sslvolume letsencryptvolume

# 0a. If the gocryptfs-passphrase Secret is ALREADY present (e.g. an
#     operator provisioned it via External Secrets Operator ahead of
#     this migration), validate its shape BEFORE the destructive
#     scale-to-0 step below. A Secret with no `passphrase` key, or a
#     key that base64-decodes to empty / whitespace-only, would ride
#     through the Secret-adoption gate in step 2, then the init Job
#     would refuse at mount time — by which point the running
#     deployment has already been scaled down and the migration is
#     half-committed. Fail fast here instead.
#
#     Only validate when the Secret is present; the Secret-adoption
#     gate in step 2 handles the absent case. Treat a kubectl API
#     error on the probe the same way the adoption gate does:
#     an indeterminate cluster state must not proceed to the
#     destructive scale-down.
secret_probe_err=$(mktemp)
if kubectl get secret gocryptfs-passphrase -o name >/dev/null 2>"$secret_probe_err"; then
  passphrase_b64=$(kubectl get secret gocryptfs-passphrase \
                   -o jsonpath='{.data.passphrase}' 2>/dev/null || true)
  if [ -z "$passphrase_b64" ]; then
    echo "ERROR: Secret 'gocryptfs-passphrase' exists but has no 'passphrase' key."
    echo "       Refusing to scale openemr to 0 — fix the Secret shape first."
    rm -f "$secret_probe_err"
    exit 1
  fi
  decoded_len=$(printf '%s' "$passphrase_b64" | base64 -d 2>/dev/null \
                | tr -d '[:space:]' | wc -c | tr -d ' ')
  if [ "$decoded_len" = "0" ]; then
    echo "ERROR: Secret 'gocryptfs-passphrase' 'passphrase' key decodes to empty/whitespace."
    echo "       Refusing to scale openemr to 0 — fix the Secret value first."
    rm -f "$secret_probe_err"
    exit 1
  fi
elif ! grep -qi 'NotFound\|not found' "$secret_probe_err"; then
  echo "ERROR: kubectl get secret gocryptfs-passphrase returned an API error that is NOT NotFound:"
  cat "$secret_probe_err" >&2
  echo "       Refusing to scale openemr to 0 — cluster state is indeterminate."
  rm -f "$secret_probe_err"
  exit 1
fi
rm -f "$secret_probe_err"

# Wait for openemr pods to reach Ready AND verify that the leader
# completed its first-boot seed. openemr's first-boot writes
# sqlconf.php and seeds the admin user + Gacl rows; scaling to 0
# before that completes would carry partial state through the
# migration and the next boot inside gocryptfs would skip first-boot
# while the DB is still incomplete (the AclMain::testAclCheckCore
# flake).
#
# Pod Ready alone is not quite enough on its own, even though the
# default Deployment's readinessProbe is `cat /root/instance-swarm-
# ready` which is only written after leader-election + setup
# completes. The reason: `kubectl wait --for=condition=Ready` with a
# label selector operates on the resources that match at invocation
# time, and in the "pods scheduled but not yet Ready" window a
# follower that has decided "leader marker exists → skip to fast
# path" can satisfy Ready before the leader has finished writing
# `$config = 1` to sqlconf.php (openemr's leader-election commits
# the full seed, THEN flips the $config flag — the two-phase pattern
# openemr/openemr#15084 formalized). Explicitly check sqlconf.php on
# websitevolume shows `$config = 1`; that is the true "seed
# complete" signal.
#
# The `&&` chain is load-bearing: if the wait times out (first-boot
# wedged on some other issue — ganesha misbehaving, MySQL not
# reachable, etc.) the scale command must NOT run. Scaling partial
# first-boot preserves a half-configured sqlconf.php that the next
# boot inside gocryptfs would then accept as "already configured"
# and skip setup, leaving the DB without the initial admin user.
kubectl wait --for=condition=Ready -l name=openemr pod --timeout=1200s \
  && \
  # Verify the leader has committed the two-phase seed. $config = 1
  # is written AFTER all seeding steps commit, so this flag's
  # presence proves the admin user and GACL rows are in place.
  kubectl exec deploy/openemr -c openemr -- \
    sh -c 'grep -q "^\$config *= *1" /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php' \
  && \
  # 1. Scale openemr to 0 so no pod is holding websitevolume open.
  kubectl scale deployment openemr --replicas=0
# Wait for pod deletion AND verify no pod is still present. `kubectl
# wait --for=delete` returns success on the first termination event
# it observes on each Pod it snapshotted at invocation time, but can
# race: a Pod that is deleting slowly (e.g. stuck in Terminating on
# a lingering mount) may still exist when the wait returns. Follow
# up with a hard check that NO pod is still holding the
# `websitevolume` PVC open — if ANY remains, the migration MUST
# abort. Proceeding past this point with a live writer still holding
# websitevolume lets the plaintext rsync step race the pod's own
# writes, corrupting the migration. Fall through to manual recovery
# (investigate the stuck pod, `kubectl delete pod --force` only as
# last resort — it strands the mount, which requires node-level
# cleanup but at least stops NEW writes).
#
# Enumerate ALL pods in the namespace (no label selector) and inspect
# each one's `.spec.volumes[*].persistentVolumeClaim.claimName` for
# `websitevolume`. Label-scoped probes (`-l name=openemr`) miss
# writers whose labels were rotated — a canary with `track=canary`, a
# rename-in-place, or a one-off debug pod that mounted the PVC for
# a copy would all slip past. The PVC-mount signal is what we
# actually care about (anything holding the volume open corrupts the
# migration), so inspect it directly.
#
# NOTE on the jsonpath shape. The naive form
#   {range .items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=="websitevolume")]}
# expands an ARRAY on the left of ==; the behavior of that comparison
# is inconsistent across kubectl versions and jsonpath
# implementations (some emit the pod once, some emit per-matching-
# volume, some skip entirely). Use the robust form instead: print
# `<podName> <claimName1> <claimName2> ...` for every pod, then
# awk-filter rows whose second-or-later column equals websitevolume.
# This matches claimName as a whole field (not a substring) and
# survives pods with multiple PVCs.
#
# COVERAGE note. This probe catches the common case (pods mounting
# the websitevolume PVC in this namespace). It does NOT catch:
#   - pods with direct NFS volumeMounts bypassing the PVC
#   - pods in OTHER namespaces that happen to mount the same NFS
#     share via their own PVCs (unusual in this stack, but possible)
#   - external NFS clients from outside the cluster
# If your topology is non-standard on any of those axes, verify
# quiescence from THAT side (e.g. inspect the NFS server's active
# client list) BEFORE proceeding — a live writer from any of those
# sources would race the rsync-in step and corrupt the migration.
#
# Capture stderr separately. A kubectl API-call failure must NOT be
# conflated with "no matching pods" — prior `2>/dev/null`/`2>&1`
# patterns would either hide the error entirely or fold it onto
# stdout where the emptiness check would misread it as a pod name.
kubectl wait --for=delete pod -l name=openemr --timeout=120s || true
err_file=$(mktemp)
if ! probe=$(kubectl get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}' \
    2>"$err_file"); then
  echo "ERROR: kubectl get pods failed — cannot verify websitevolume is quiescent."
  cat "$err_file"
  rm -f "$err_file"
  exit 1
fi
rm -f "$err_file"
# Post-filter in awk: print the pod name (column 1) if any later
# column (claimName) equals "websitevolume". Whole-field match, no
# substring collisions (e.g. "websitevolume-backup" won't trip).
remaining=$(printf '%s\n' "$probe" | awk '
  NF >= 2 { for (i = 2; i <= NF; i++) if ($i == "websitevolume") { print $1; next } }
')
if [ -n "$remaining" ]; then
  echo "ERROR: pods still hold websitevolume after scale-to-0 + delete wait — aborting:"
  echo "$remaining"
  exit 1
fi

# 2. Create the gocryptfs passphrase Secret. In production, replace this
#    with an ESO-managed ExternalSecret.
#    EDIT the passphrase in gocryptfs-passphrase-secret.yaml FIRST.
#
# Apply the manifest ONLY when the Secret does not already exist in
# the target namespace — an unconditional `kubectl apply` would
# overwrite an ESO-managed Secret with the public placeholder, and the
# init Job would then refuse to run against it (its guard rejects the
# placeholder value). If ESO manages this Secret, do NOT apply the
# local manifest at all; let ESO own the lifecycle.
#
# The lookup distinguishes three outcomes:
#   * exists         → NOT applying; surface placeholder warning;
#   * confirmed-absent → create (not apply) so a concurrent ESO
#                      creation between our check and our create loses
#                      cleanly with AlreadyExists rather than racing
#                      an overwrite;
#   * other API error → ABORT (RBAC denied, API server unreachable,
#                      network blip). The bare `>/dev/null 2>&1` arm
#                      swallowed all of these as "does not exist" and
#                      proceeded to apply the placeholder on top of
#                      whatever state the cluster was actually in.
secret_err=$(mktemp)
if kubectl get secret gocryptfs-passphrase -o name >/dev/null 2>"$secret_err"; then
  echo "Secret 'gocryptfs-passphrase' already exists — NOT applying the local manifest."
  existing=$(kubectl get secret gocryptfs-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
             | base64 -d 2>/dev/null || true)
  if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
    echo "WARNING: existing Secret still carries the published placeholder"
    echo "passphrase. The init Job will refuse to run against it."
  fi
elif grep -qi 'NotFound\|not found' "$secret_err"; then
  # Confirmed not found — create. `kubectl create` fails with
  # AlreadyExists on a concurrent ESO creation, which is the
  # correct outcome: we'd rather lose the race than overwrite.
  if ! kubectl create -f gocryptfs-passphrase-secret.yaml 2>"$secret_err"; then
    if grep -qi 'AlreadyExists\|already exists' "$secret_err"; then
      echo "Secret 'gocryptfs-passphrase' was created concurrently (likely by ESO) — NOT overwriting."
      existing=$(kubectl get secret gocryptfs-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
                 | base64 -d 2>/dev/null || true)
      if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
        echo "WARNING: concurrently-created Secret still carries the published"
        echo "placeholder passphrase. The init Job will refuse to run against it."
      fi
    else
      echo "ERROR: kubectl create secret gocryptfs-passphrase failed:"
      cat "$secret_err" >&2
      rm -f "$secret_err"
      exit 1
    fi
  fi
else
  echo "ERROR: kubectl get secret gocryptfs-passphrase returned an API error that is NOT NotFound:"
  cat "$secret_err" >&2
  echo "       Refusing to proceed — the cluster state is indeterminate."
  rm -f "$secret_err"
  exit 1
fi
rm -f "$secret_err"

# 3. Run the one-shot init Job. This initializes the gocryptfs backing
#    directory (gocryptfs.conf + gocryptfs.diriv) inside websitevolume.
#    Near-instant.
kubectl apply -f gocryptfs-init-job.yaml
kubectl wait --for=condition=complete job/gocryptfs-init-websitevolume --timeout=120s
kubectl logs job/gocryptfs-init-websitevolume

# 3b. MIGRATE existing plaintext sites contents INTO the gocryptfs backing.
#     The init Job only creates gocryptfs.conf/gocryptfs.diriv in the new
#     backing directory; anything already on websitevolume (uploaded
#     documents, site config, cert material inside sites/default) is still
#     plaintext at the top of websitevolume alongside the new
#     gocryptfs-backing/ subdir. After the Deployment swap (step 4), the
#     main container no longer mounts websitevolume directly — so without
#     this step the prior contents become stranded.
#
#     Run a short-lived privileged helper pod that mounts websitevolume,
#     fuse-mounts the gocryptfs backing dir, rsyncs the plaintext sites
#     contents into the decrypted view, verifies, DELETES THE PLAINTEXT
#     ORIGINALS, unmounts, then exits. Tailor this to your environment:
#     the shape is:
#
#       mount websitevolume at /ws
#       gocryptfs -sharedstorage \
#         -passfile /etc/gocryptfs/passphrase \
#         /ws/gocryptfs-backing /dec
#       # Verify the FUSE mount is really live BEFORE rsyncing. If
#       # gocryptfs silently fell back to a plain-directory write
#       # (e.g. FUSE handshake failed and the process exited leaving
#       # /dec as a regular directory on the pod rootfs), the rsync
#       # below would write PLAINTEXT to that directory — the opposite
#       # of the goal. Confirm /proc/mounts reports a fuse/fuse.gocryptfs
#       # entry at /dec and abort otherwise.
#       fs=$(awk '$2 == "/dec" { print $3 }' /proc/mounts | tail -1)
#       case "$fs" in
#         fuse|fuse.gocryptfs) echo "verified gocryptfs mount at /dec (type=$fs)" ;;
#         *) echo "ERROR: /dec is not a live FUSE mount (type='$fs') — aborting"; exit 1 ;;
#       esac
#       # Anchor the exclude to the transfer root with a leading slash so
#       # it matches ONLY /ws/gocryptfs-backing. An unanchored
#       # `--exclude=gocryptfs-backing` would also skip any plaintext
#       # subdirectory that happens to carry the same name at depth.
#       rsync -aHAX --exclude=/gocryptfs-backing /ws/ /dec/
#       # Verify counts and spot-check files before proceeding.
#       # Example verification (compare file counts):
#       SRC_COUNT=$(find /ws -mindepth 1 -maxdepth 20 -type f \
#         -not -path '/ws/gocryptfs-backing*' | wc -l)
#       DST_COUNT=$(find /dec -mindepth 1 -maxdepth 20 -type f | wc -l)
#       [ "$SRC_COUNT" = "$DST_COUNT" ] || { echo "MISMATCH"; exit 1; }
#       fusermount3 -u /dec
#
#     Then REMOVE the plaintext originals from /ws (everything except
#     gocryptfs-backing/). This is REQUIRED, not optional: leaving them
#     in place means the NFS backing continues to store PHI in
#     plaintext, defeating the entire purpose of adopting this example.
#     The marker-based validate-encryption.sh does NOT detect stray
#     plaintext from a prior setup — it only proves that a fresh
#     writes-via-decrypted-mount round-trips to ciphertext. Operators
#     who skip this step have a false sense of compliance.
#
#     Re-verify the copy count ONE MORE TIME immediately before the
#     destructive `rm -rf` — a FUSE unmount or NFS flush between the
#     verification above and here would be caught here instead of
#     silently deleting plaintext that never reached the backing dir.
#     This is cheap defensive insurance; `find | wc -l` of a seeded
#     openemr `sites/` is well under a second.
#
#       # Re-mount read-only purely for the count. Any mismatch at this
#       # point is a hard stop — do NOT proceed to the delete.
#       gocryptfs -ro -sharedstorage \
#         -passfile /etc/gocryptfs/passphrase \
#         /ws/gocryptfs-backing /dec
#       fs=$(awk '$2 == "/dec" { print $3 }' /proc/mounts | tail -1)
#       case "$fs" in
#         fuse|fuse.gocryptfs) ;;
#         *) echo "ERROR: /dec remount not FUSE — aborting delete"; exit 1 ;;
#       esac
#       SRC_COUNT=$(find /ws -mindepth 1 -maxdepth 20 -type f \
#         -not -path '/ws/gocryptfs-backing*' | wc -l)
#       DST_COUNT=$(find /dec -mindepth 1 -maxdepth 20 -type f | wc -l)
#       fusermount3 -u /dec
#       [ "$SRC_COUNT" = "$DST_COUNT" ] || {
#         echo "ERROR: pre-delete count mismatch (src=$SRC_COUNT dst=$DST_COUNT) — aborting"
#         exit 1
#       }
#       # Only now delete the plaintext originals.
#       find /ws -mindepth 1 -maxdepth 1 ! -name 'gocryptfs-backing' \
#         -exec rm -rf {} +
#       # Alternative: relocate the plaintext originals to trusted
#       # storage (encrypted PV, KMS-backed object storage, etc.) if
#       # retention is required for audit.
#
#     After this step, `ls /ws` must show exactly one entry:
#     gocryptfs-backing/.

# 4. Replace the default openemr Deployment with the gocryptfs-enabled one.
#    This REMOVES the existing openemr Deployment and creates the new
#    multi-replica, gocryptfs-sidecar version.
kubectl delete deployment openemr
kubectl apply -f openemr-deployment-gocryptfs.yaml

# 5. Watch the pods come up. The gocryptfs-mounter sidecar must become
#    Ready before each openemr container starts. All 3 replicas roll
#    independently thanks to RollingUpdate.
kubectl get pods -l name=openemr -w

# 6. (Optional) Validate that the encryption is actually effective.
#    Default run: gocryptfs.conf parse + cipher check + filename-leak
#    check + sampled (4 MiB per file) content-leakage scan. Fast.
./validate-encryption.sh

#    For paranoia-level coverage, set VALIDATE_FULL=1 to additionally
#    scan the *full contents* of every backing file for the marker.
#    Takes several minutes on a seeded install over NFS.
VALIDATE_FULL=1 ./validate-encryption.sh
```

> [!NOTE]
> The `validate-encryption.sh` scan (both the default sampled form and
> `VALIDATE_FULL=1`) only searches for the **test marker it just
> wrote**. A PASS proves that *this specific just-written write*
> ended up as ciphertext on NFS — which is the semantics we want to
> verify for the gocryptfs setup. It does **not** scan for arbitrary
> plaintext anywhere in the backing dir, and in particular it does
> **not** detect plaintext originals left behind on `websitevolume`
> outside the `gocryptfs-backing/` subdir by an incomplete migration
> step. If you are concerned about stray plaintext from a prior setup,
> inspect `/mnt/websitevolume/` from inside the `gocryptfs-mounter`
> sidecar after migration and confirm that only `gocryptfs-backing/`
> remains at the top level.

### Greenfield adoption (no plaintext first-boot)

Use this path when you need `sqlconf.php` (which carries the DB password) and the initial GACL seed to ONLY ever exist inside the gocryptfs mount — never as a plaintext file on `websitevolume`. The migration path above lets openemr first-boot land on plaintext NFS and then moves it under encryption afterwards; this path initializes the gocryptfs backing BEFORE openemr first-boot ever runs.

The sequence relies on racing kubelet: `kub-up` creates the default openemr Deployment, and a pod is scheduled immediately. You must delete the Deployment (and let the pod terminate) before its startup script writes `sqlconf.php`. In practice first-boot takes minutes to complete (leader-election + schema install + demo seed), so there is comfortable headroom, but you still need to act promptly and check that no pod has advanced past the swarm-ready marker.

```bash
# 0. Bring up the default stack. This creates the mysql, redis,
#    ganesha-nfs, phpmyadmin, and openemr Deployments. openemr pods
#    begin first-boot immediately.
./kubernetes/kub-up

# 1. IMMEDIATELY delete the openemr Deployment before its pods
#    advance through first-boot. The `--ignore-not-found` allows
#    this to be idempotent if it ran during a kubelet gap.
kubectl delete deployment openemr --ignore-not-found
# Fail the setup if any old openemr writer pod survives the delete
# wait — proceeding past that point could race a still-finishing
# first-boot and land plaintext on NFS between the precheck and the
# gocryptfs init step. Accept the "already empty" case where kubectl
# wait on an empty pod set returns non-zero.
#
# Fail closed if the `kubectl get pods` probe itself errors. A
# command-not-found, auth failure, or apiserver outage returns a
# non-zero exit AND an empty stdout — `[ -z "" ]` would then pass
# vacuously and let the pipeline proceed with no idea whether pods
# remain. Capture the two signals (stdout + exit) separately.
kubectl wait --for=delete pod -l name=openemr --timeout=120s || true
if ! probe=$(kubectl get pods -l name=openemr -o name 2>&1); then
  echo "ERROR: could not list openemr pods to verify delete: $probe"
  exit 1
fi
if [ -n "$probe" ]; then
  echo "ERROR: openemr pods remained after delete wait — aborting:"
  echo "$probe"
  exit 1
fi

# 2. Defensive check: confirm no plaintext openemr state exists on
#    websitevolume. The greenfield guarantee is "no plaintext data on
#    NFS", which means the volume must be empty before the gocryptfs
#    backing dir is initialized. Scoping the check to sqlconf.php
#    alone would miss uploaded documents, cert material, or any other
#    partially-landed state from a prior aborted first-boot (e.g. a
#    pod that wrote documents before being killed). Insist on an
#    empty volume, with a narrow carve-out for the gocryptfs init
#    artifacts (gocryptfs-backing/) in case init already succeeded on
#    a prior attempt.
#
#    Clean up any stale precheck pod from a prior attempt BEFORE the
#    apply. `kubectl apply` on an existing pod with a different spec
#    is a no-op (the Pod kind rejects most spec mutations) and would
#    leave us reading stale state from the old pod. --wait=true
#    ensures the old pod is fully gone before we recreate.
if ! kubectl delete pod greenfield-precheck --ignore-not-found --wait=true; then
  echo "ERROR: failed to remove stale greenfield-precheck pod from a prior attempt."
  exit 1
fi
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: greenfield-precheck
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  # Container name is load-bearing: the `kubectl wait` below filters
  # on containerStatuses[?(@.name=="precheck")], so renaming here
  # requires updating the wait expression too.
  - name: precheck
    image: alpine:3.24
    command: ["/bin/sh", "-c"]
    args:
      - |
        # Four distinct outcomes:
        #  - mount unreachable (dir missing or unlistable): exit 2
        #    (PRECHECK_UNKNOWN) — the operator must diagnose, not
        #    mistake a broken check for a passing one.
        #  - any entry besides the gocryptfs-backing/ carve-out: exit 1
        #    (EXISTING_DATA_PRESENT) — the greenfield guarantee is
        #    lost. Fall back to the migration path.
        #  - exactly the carve-out entries (gocryptfs-backing/ alone,
        #    from a prior successful init): exit 0 — the greenfield
        #    sequence can resume from the Deployment-apply step.
        #  - truly empty: exit 0 — proceed with the full greenfield
        #    sequence.
        if [ ! -d /mnt/websitevolume ]; then
          echo "PRECHECK_UNKNOWN: /mnt/websitevolume is not accessible as a directory"
          exit 2
        fi
        # Probe the directory itself before trusting the entry listing.
        # `ls` failing on the mountpoint indicates a permissions or
        # NFS-visibility problem distinct from "volume is empty"; we
        # must not treat that as PRECHECK_OK.
        if ! ls /mnt/websitevolume >/dev/null 2>&1; then
          echo "PRECHECK_UNKNOWN: cannot list /mnt/websitevolume"
          exit 2
        fi
        # Enumerate top-level entries into a tempfile so we can
        # iterate without an inline heredoc (which would collide with
        # the outer YAML block scalar's indentation rules). `ls -A`
        # includes dotfiles but omits . and ..; iterate line-by-line
        # and match each against the allowlist. Use a semicolon-
        # separated accumulator so the diagnostic list stays on one
        # line (embedded newlines in a shell variable would complicate
        # the YAML-embedded block scalar further down, and we do not
        # need line breaks in the message).
        ls_out=$(mktemp)
        if ! ls -A /mnt/websitevolume >"$ls_out" 2>/dev/null; then
          echo "PRECHECK_UNKNOWN: ls -A failed on /mnt/websitevolume"
          rm -f "$ls_out"
          exit 2
        fi
        unexpected=""
        saw_backing=0
        while IFS= read -r entry; do
          [ -z "$entry" ] && continue
          case "$entry" in
            # Carve-outs: the gocryptfs init Job's artifacts. If init
            # already ran (prior-attempt resume), the backing dir is
            # permitted at the top level — BUT its contents must match
            # what `gocryptfs -init` creates and nothing else (see the
            # backing-dir shape verification below).
            gocryptfs-backing) saw_backing=1 ;;
            *)
              if [ -z "$unexpected" ]; then
                unexpected="$entry"
              else
                unexpected="$unexpected; $entry"
              fi
              ;;
          esac
        done <"$ls_out"
        rm -f "$ls_out"
        if [ -n "$unexpected" ]; then
          echo "EXISTING_DATA_PRESENT: /mnt/websitevolume holds entries beyond the allowlist: $unexpected"
          echo "The greenfield guarantee requires an empty volume (or only"
          echo "gocryptfs-backing/ from a prior-attempt init). Fall back to"
          echo "the migration path, or wipe websitevolume and retry."
          exit 1
        fi
        # Resume-path shape check. The top-level allowlist let
        # gocryptfs-backing/ through as a "prior init artifact", but
        # mere directory existence is not enough: a half-written init
        # (OOM-killed, node crash during gocryptfs -init), a corrupted
        # backing dir, or plaintext dumped inside gocryptfs-backing/ by
        # a misconfigured migration helper would all present as
        # "directory exists". `gocryptfs -init` creates exactly two
        # files at the top level of the backing dir — gocryptfs.conf
        # and gocryptfs.diriv — nothing else. Verify that invariant
        # before telling the operator to resume; any deviation means
        # the init state is not trustworthy and manual inspection is
        # required.
        if [ "$saw_backing" = "1" ]; then
          if [ ! -d /mnt/websitevolume/gocryptfs-backing ]; then
            echo "PRECHECK_UNKNOWN: /mnt/websitevolume/gocryptfs-backing is listed but not a directory"
            exit 2
          fi
          backing_ls=$(mktemp)
          if ! ls -A /mnt/websitevolume/gocryptfs-backing >"$backing_ls" 2>/dev/null; then
            echo "PRECHECK_UNKNOWN: cannot list /mnt/websitevolume/gocryptfs-backing"
            rm -f "$backing_ls"
            exit 2
          fi
          backing_unexpected=""
          saw_conf=0
          saw_diriv=0
          while IFS= read -r bentry; do
            [ -z "$bentry" ] && continue
            case "$bentry" in
              gocryptfs.conf)  saw_conf=1 ;;
              gocryptfs.diriv) saw_diriv=1 ;;
              *)
                if [ -z "$backing_unexpected" ]; then
                  backing_unexpected="$bentry"
                else
                  backing_unexpected="$backing_unexpected; $bentry"
                fi
                ;;
            esac
          done <"$backing_ls"
          rm -f "$backing_ls"
          if [ -n "$backing_unexpected" ] || [ "$saw_conf" != "1" ] || [ "$saw_diriv" != "1" ]; then
            echo "EXISTING_DATA_PRESENT: /mnt/websitevolume/gocryptfs-backing has an unexpected shape."
            echo "  saw gocryptfs.conf:  $saw_conf (expected 1)"
            echo "  saw gocryptfs.diriv: $saw_diriv (expected 1)"
            echo "  unexpected entries:  ${backing_unexpected:-<none>}"
            echo "A clean 'gocryptfs -init' leaves EXACTLY gocryptfs.conf +"
            echo "gocryptfs.diriv. Anything else (missing file, extra file,"
            echo "plaintext remnants, half-written state) means the prior"
            echo "init did not complete cleanly, or something has written"
            echo "into the backing dir out-of-band. DO NOT resume — inspect"
            echo "manually. Typical recovery: delete /mnt/websitevolume/"
            echo "gocryptfs-backing entirely and run the init Job fresh"
            echo "(only safe if you also confirm no encrypted data was"
            echo "written yet)."
            exit 1
          fi
          # Shape check accepted gocryptfs.conf by name, but that file
          # could be empty, truncated by an OOM-killed init, or
          # overwritten with non-JSON. A corrupted gocryptfs.conf would
          # sail past the name-only check here and detonate at mount
          # time (gocryptfs-mounter crash-loops with a cryptic parse
          # error). Validate the config JSON here — before telling the
          # operator "resume is safe" — by parsing it as JSON and
          # requiring the fields `gocryptfs -init` always writes
          # (Creator, EncryptedKey, FeatureFlags).
          #
          # Alpine does not ship jq by default and py3 is overkill for
          # this; `apk add jq` is <400 KB and matches the install
          # pattern the LUKS precheck uses for cryptsetup.
          if ! apk add --no-cache jq >/dev/null 2>&1; then
            echo "PRECHECK_UNKNOWN: failed to install jq for gocryptfs.conf validation"
            exit 2
          fi
          conf_path=/mnt/websitevolume/gocryptfs-backing/gocryptfs.conf
          if ! jq -e 'has("Creator") and has("EncryptedKey") and has("FeatureFlags")' \
               "$conf_path" >/dev/null 2>&1; then
            echo "EXISTING_DATA_PRESENT: $conf_path is malformed."
            echo "The file is not parseable as JSON, or is missing one of the"
            echo "required fields that 'gocryptfs -init' always writes:"
            echo "Creator, EncryptedKey, FeatureFlags. An empty / truncated /"
            echo "non-JSON gocryptfs.conf would pass the name-only check but"
            echo "then fail at mount time with a cryptic parse error. DO NOT"
            echo "resume — inspect manually. Typical recovery: delete /mnt/"
            echo "websitevolume/gocryptfs-backing entirely and run the init"
            echo "Job fresh (only safe if you also confirm no encrypted data"
            echo "was written yet)."
            exit 1
          fi
          # Field-presence is cheap but shallow — a truncated EncryptedKey
          # (invalid base64) or a Version field for a format the running
          # gocryptfs cannot speak will both pass `has()` and then fail
          # at `gocryptfs -info` / mount time. Tighten here with two
          # content checks the init emits deterministically:
          #
          #   * EncryptedKey must base64-decode cleanly. gocryptfs writes
          #     the wrapped master key as base64; a corrupted write would
          #     be caught by `gocryptfs -info` but only after we've told
          #     the operator "resume is safe". Validate up front.
          #
          #   * Version, if present, must be an integer in the supported
          #     range (format v2 is current; v1 has been the only other
          #     widely-shipped value). A non-integer or out-of-range
          #     value signals a format gocryptfs cannot speak, and we
          #     must not route it through the RESUME path. Missing
          #     Version is tolerated (very old configs predate it).
          enc_key=$(jq -r '.EncryptedKey // empty' "$conf_path")
          if [ -z "$enc_key" ] || ! printf '%s' "$enc_key" | base64 -d >/dev/null 2>&1; then
            echo "EXISTING_DATA_PRESENT: $conf_path has an EncryptedKey that does not base64-decode."
            echo "gocryptfs writes the wrapped master key as base64; a value"
            echo "that fails to decode means the file was truncated / corrupted"
            echo "/ hand-edited. DO NOT resume — inspect manually."
            exit 1
          fi
          version=$(jq -r '.Version // empty' "$conf_path")
          if [ -n "$version" ]; then
            case "$version" in
              1|2) ;;
              *)
                echo "EXISTING_DATA_PRESENT: $conf_path declares Version='$version'."
                echo "gocryptfs config format Version must be 1 or 2. An unknown"
                echo "value means the file is from a future gocryptfs or is"
                echo "corrupted. DO NOT resume — inspect manually."
                exit 1
                ;;
            esac
          fi
          # gocryptfs.diriv is the directory-level IV file; in the
          # current on-disk format it is exactly 16 bytes. The shape
          # check above accepted it by name — accept it by size next.
          # An empty file would pass the name-only check and fail at
          # mount time with "gocryptfs.diriv: file is 0 bytes long".
          # At minimum, require non-empty (-s); the exact-16-byte check
          # follows for operator diagnostics on the odd case.
          diriv_path=/mnt/websitevolume/gocryptfs-backing/gocryptfs.diriv
          if [ ! -s "$diriv_path" ]; then
            echo "EXISTING_DATA_PRESENT: $diriv_path is empty."
            echo "A clean 'gocryptfs -init' writes exactly 16 bytes of random"
            echo "directory IV. An empty file would pass the name-only check"
            echo "but fail at mount time. DO NOT resume — inspect manually."
            exit 1
          fi
          diriv_size=$(wc -c <"$diriv_path" | tr -d ' ')
          if [ "$diriv_size" != "16" ]; then
            echo "EXISTING_DATA_PRESENT: $diriv_path is $diriv_size bytes (expected 16)."
            echo "The current gocryptfs on-disk format stores the directory IV"
            echo "as exactly 16 bytes. A different size means the file was"
            echo "truncated, extended, or is from a format this precheck has"
            echo "not been updated to recognize. DO NOT resume — inspect manually."
            exit 1
          fi
          echo "PRECHECK_OK: RESUME — /mnt/websitevolume holds a well-formed gocryptfs-backing/ from a prior init; skip the init Job and proceed to Deployment apply"
          exit 0
        fi
        echo "PRECHECK_OK: EMPTY — /mnt/websitevolume is empty; proceed with the full greenfield sequence (init Job, then Deployment apply)"
    volumeMounts:
      - name: websitevolume
        mountPath: /mnt/websitevolume
        readOnly: true
  volumes:
    - name: websitevolume
      persistentVolumeClaim:
        claimName: websitevolume
EOF
# The pod exits:
#   0 — PRECHECK_OK (volume empty or only gocryptfs-backing/; proceed with greenfield)
#   1 — EXISTING_DATA_PRESENT (plaintext entries present; MUST fall back to migration path)
#   2 — PRECHECK_UNKNOWN (couldn't inspect — mountpoint missing, ls failed, etc.; DIAGNOSE, don't blindly migrate)
#
# Wait on the NAMED container's termination, not pod phase. A pod
# with multiple containers could be Pending/Running while the probe
# container has already terminated with an exit code — pod-phase
# wait would miss that.
#
# Poll for the precheck container's terminated state via
# `go-template` rather than `kubectl wait --for=jsonpath=` with a
# filter expression. `kubectl wait --for=jsonpath` landed in 1.23
# but filter expressions INSIDE that jsonpath against an array
# (containerStatuses[?(@.name=="precheck")]) were not reliably
# supported until kubectl 1.29; on 1.28 the expression either
# returns "no matches" immediately or times out silently. The
# go-template form below works on every supported kubectl release
# because it runs client-side after the get completes.
EXIT_CODE=""
for attempt in $(seq 1 60); do
  EXIT_CODE=$(kubectl get pod greenfield-precheck \
    -o go-template='{{range .status.containerStatuses}}{{if eq .name "precheck"}}{{if .state.terminated}}{{.state.terminated.exitCode}}{{end}}{{end}}{{end}}' \
    2>/dev/null || echo "")
  if [ -n "$EXIT_CODE" ]; then
    break
  fi
  sleep 1
done

if [ "$EXIT_CODE" = "0" ]; then
  # Precheck exit 0 covers two sub-cases that take different downstream
  # paths: EMPTY (run the init Job) vs RESUME (a prior init already
  # created a well-formed gocryptfs-backing/ — the init Job is at best
  # redundant, and its own guard would refuse to re-init on top of it).
  # The precheck container's final log line distinguishes the two
  # (PRECHECK_OK: EMPTY vs PRECHECK_OK: RESUME); capture the logs here
  # BEFORE deleting the pod so the signal survives.
  #
  # Fail-closed classification. The precheck container exited 0, but
  # exit 0 alone does not tell us WHICH of the two safe outcomes it
  # saw — only its log line does. `kubectl logs` can fail independently
  # of container exit (API glitch, pod GC race, authz on logs subresource)
  # and return an empty string under `|| true`. Branching on "RESUME
  # marker present → RESUME, everything else → EMPTY" would silently
  # route a log-read failure OR an unclassified marker through the
  # EMPTY arm — which runs the init Job, and the init Job's own guard
  # refuses to re-init on top of an existing backing, so the symptom
  # would be a failed Job on a resume attempt. Classify three ways
  # explicitly: RESUME marker, EMPTY marker, or ABORT.
  PRECHECK_LOG_ERR=$(mktemp)
  PRECHECK_LOG=$(kubectl logs pod/greenfield-precheck 2>"$PRECHECK_LOG_ERR") || PRECHECK_LOG_FAILED=yes
  if [ "${PRECHECK_LOG_FAILED:-no}" = "yes" ]; then
    echo "ERROR: kubectl logs pod/greenfield-precheck failed — cannot classify precheck outcome."
    echo "       The container exited 0, but without its log line we cannot tell"
    echo "       EMPTY (run init Job) from RESUME (skip init Job). ABORTING."
    cat "$PRECHECK_LOG_ERR" >&2
    rm -f "$PRECHECK_LOG_ERR"
    kubectl delete pod greenfield-precheck --ignore-not-found
    exit 2
  fi
  rm -f "$PRECHECK_LOG_ERR"
  if printf '%s\n' "$PRECHECK_LOG" | grep -q '^PRECHECK_OK: RESUME'; then
    RESUME=yes
    echo "Greenfield precheck PASSED (RESUME) — websitevolume already holds a well-formed gocryptfs-backing/ from a prior init. The init Job will be SKIPPED below."
  elif printf '%s\n' "$PRECHECK_LOG" | grep -q '^PRECHECK_OK: EMPTY'; then
    RESUME=no
    echo "Greenfield precheck PASSED (EMPTY) — websitevolume is empty. The init Job will run below."
  else
    echo "ERROR: greenfield-precheck exited 0 but its log contains neither"
    echo "       'PRECHECK_OK: RESUME' nor 'PRECHECK_OK: EMPTY'. Something"
    echo "       truncated the log or changed the precheck script without"
    echo "       updating the classifier. ABORTING — do NOT guess at the"
    echo "       downstream path."
    echo ""
    echo "--- captured log ---"
    printf '%s\n' "$PRECHECK_LOG"
    echo "--- end captured log ---"
    kubectl delete pod greenfield-precheck --ignore-not-found
    exit 2
  fi
  kubectl delete pod greenfield-precheck
else
  # Precheck container exited non-zero OR did not terminate within
  # the poll window. Capture diagnostics BEFORE deleting the pod
  # (describing a missing resource produces no useful output).
  echo ""
  echo "--- diagnostics for greenfield-precheck (captured pre-delete) ---"
  kubectl describe pod/greenfield-precheck 2>/dev/null || echo "(describe failed)"
  echo ""
  echo "--- logs for greenfield-precheck ---"
  kubectl logs pod/greenfield-precheck 2>/dev/null || echo "(logs failed)"
  echo "--- end diagnostics ---"
  echo ""
  case "$EXIT_CODE" in
    1)
      echo "Greenfield precheck result: EXISTING_DATA on websitevolume."
      echo "Greenfield guarantee is lost. Fall back to the Migration path"
      echo "(§ 'Migration from a running default-stack deployment' above)."
      echo "BEFORE doing so, clean up partial greenfield artifacts:"
      echo "  - kubectl delete pod greenfield-precheck --ignore-not-found"
      echo "  - kubectl delete job gocryptfs-init-websitevolume --ignore-not-found"
      echo "  - If the gocryptfs-passphrase Secret came from this attempt"
      echo "    (i.e. you applied gocryptfs-passphrase-secret.yaml directly"
      echo "    in step 3 below): kubectl delete secret gocryptfs-passphrase"
      echo "    If it came from External Secrets Operator (ESO) or any other"
      echo "    controller-managed source: DO NOT delete it — let the"
      echo "    controller reconcile. Check for ESO ownership first:"
      echo "      kubectl get secret gocryptfs-passphrase -o jsonpath='{.metadata.ownerReferences}'"
      echo "    Non-empty ownerReferences (or an annotation like"
      echo "    'external-secrets.io/managed') means another controller owns it."
      echo "  - do NOT wipe websitevolume; migration needs the plaintext data"
      kubectl delete pod greenfield-precheck --ignore-not-found
      exit 1
      ;;
    2|"")
      # Container exit 2 OR no terminated-state recorded (poll timeout).
      echo "Greenfield precheck result: UNKNOWN (container exit: '${EXIT_CODE:-timeout}')."
      echo "DIAGNOSE AND RETRY. Do NOT fall back to the migration path"
      echo "without first confirming the plaintext state of websitevolume."
      echo "The diagnostics above are the starting point; also check:"
      echo "  kubectl get pvc websitevolume"
      kubectl delete pod greenfield-precheck --ignore-not-found
      exit 2
      ;;
    *)
      echo "Greenfield precheck: unexpected container exit code '${EXIT_CODE}' — DIAGNOSE."
      kubectl delete pod greenfield-precheck --ignore-not-found
      exit 2
      ;;
  esac
fi

# 3. Create the gocryptfs passphrase Secret.
#    EDIT the passphrase in gocryptfs-passphrase-secret.yaml FIRST
#    before applying. The committed value is a public placeholder
#    and the init Job below WILL REFUSE to run against it — leaving
#    the placeholder in the Secret is not a safety net, it's a dead
#    end. In production, provision this Secret via External Secrets
#    Operator (ESO) instead of applying the placeholder manifest at
#    all; see § Key management above.
#
#    RESUME WARNING. If the precheck accepted a pre-existing
#    gocryptfs-backing/ (prior-attempt resume path), the passphrase
#    you put in this Secret MUST match the one used for the original
#    `gocryptfs -init`. The backing dir's `gocryptfs.conf` wraps the
#    master key with THAT passphrase; a new passphrase cannot open
#    the existing backing, and applying a Secret with a rotated value
#    locks you out of anything already written through this backing.
#    If you have lost the original passphrase, do NOT resume — delete
#    /mnt/websitevolume/gocryptfs-backing on the volume and start the
#    init fresh (only safe when no encrypted application data has
#    been written through this backing yet; on a true greenfield that
#    is always the case). Passphrase ROTATION of an existing backing
#    is `gocryptfs -passwd` against the backing dir, not a Secret
#    edit — see § Secret rotation in the operational notes.
#
# Apply the manifest ONLY when the Secret does not already exist in
# the target namespace. An unconditional `kubectl apply` would:
#   - overwrite an ESO-managed Secret with the public placeholder
#     (ESO will reconcile it back, but between those two events the
#     init Job may read the placeholder and refuse);
#   - on the resume path, clobber the operator-set passphrase that
#     wraps the existing gocryptfs.conf master key, which locks out
#     every subsequent mount of this backing — effectively silent
#     data loss waiting for the next pod restart.
# If ESO manages this Secret, do NOT apply the local manifest at all —
# let ESO own the lifecycle (see § Key management).
#
# Three-way classification (matches the migration path above):
#   * exists         → NOT applying; surface placeholder warning;
#   * confirmed-absent → create (not apply) so a concurrent ESO
#                      creation between our check and our create loses
#                      cleanly with AlreadyExists rather than racing
#                      an overwrite — especially critical on the resume
#                      path where overwrite = silent data loss;
#   * other API error → ABORT.
secret_err=$(mktemp)
if kubectl get secret gocryptfs-passphrase -o name >/dev/null 2>"$secret_err"; then
  echo "Secret 'gocryptfs-passphrase' already exists — NOT applying the local manifest."
  echo "If it is ESO-managed, this is the intended state. If it was left"
  echo "over from a prior run, verify its value is the passphrase used to"
  echo "initialize the existing backing dir before continuing."
  existing=$(kubectl get secret gocryptfs-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
             | base64 -d 2>/dev/null || true)
  if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
    # Rotation guidance differs between resume and fresh-init:
    #   RESUME=yes: the backing was initialized with a specific
    #     passphrase, and gocryptfs.conf wraps the master key with
    #     THAT passphrase. Editing this Secret to a new value will NOT
    #     re-wrap the on-disk master key — it locks the operator out
    #     of everything already written through the backing. The
    #     correct rotation is `gocryptfs -passwd` against the backing
    #     dir first, then update the Secret to match.
    #   RESUME=no (fresh init): the init Job has not yet created a
    #     backing, so there is no master key to protect. Editing the
    #     Secret BEFORE running the init Job is the correct move.
    if [ "${RESUME:-no}" = "yes" ]; then
      echo "WARNING: existing Secret still carries the published placeholder"
      echo "passphrase, AND the precheck selected the RESUME path."
      echo "DO NOT edit this Secret in place — the existing backing's"
      echo "gocryptfs.conf wraps the master key with whatever passphrase"
      echo "was used at init, and a new Secret value cannot decrypt it."
      echo "Rotate the backing FIRST:"
      echo "  * run \`gocryptfs -passwd /mnt/websitevolume/gocryptfs-backing\`"
      echo "    from a privileged helper pod with the old passphrase file"
      echo "    mounted; THEN"
      echo "  * update this Secret to the new passphrase."
      echo "If the old passphrase is lost, the backing is unrecoverable."
    else
      echo "WARNING: existing Secret still carries the published placeholder"
      echo "passphrase. The init Job will refuse to run against it. Replace"
      echo "the value BEFORE running the init Job (direct edit, or let ESO"
      echo "reconcile a real one)."
    fi
  fi
elif grep -qi 'NotFound\|not found' "$secret_err"; then
  if ! kubectl create -f gocryptfs-passphrase-secret.yaml 2>"$secret_err"; then
    if grep -qi 'AlreadyExists\|already exists' "$secret_err"; then
      echo "Secret 'gocryptfs-passphrase' was created concurrently (likely by ESO) — NOT overwriting."
      existing=$(kubectl get secret gocryptfs-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
                 | base64 -d 2>/dev/null || true)
      if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
        if [ "${RESUME:-no}" = "yes" ]; then
          echo "WARNING: concurrently-created Secret still carries the published"
          echo "placeholder, AND the precheck selected the RESUME path. DO NOT"
          echo "edit this Secret — rotate the backing via \`gocryptfs -passwd\`"
          echo "first (see above)."
        else
          echo "WARNING: concurrently-created Secret still carries the published"
          echo "placeholder passphrase. The init Job will refuse to run against it."
        fi
      fi
    else
      echo "ERROR: kubectl create secret gocryptfs-passphrase failed:"
      cat "$secret_err" >&2
      rm -f "$secret_err"
      exit 1
    fi
  fi
else
  echo "ERROR: kubectl get secret gocryptfs-passphrase returned an API error that is NOT NotFound:"
  cat "$secret_err" >&2
  echo "       Refusing to proceed — the cluster state is indeterminate."
  rm -f "$secret_err"
  exit 1
fi
rm -f "$secret_err"

# 4. Run the one-shot init Job against the (empty) websitevolume.
#    This creates gocryptfs.conf + gocryptfs-backing/ WITHOUT any
#    plaintext content ever landing at the top level.
#
#    RESUME path: if the precheck above set RESUME=yes, the volume
#    already holds a well-formed gocryptfs-backing/ from a prior init
#    and re-running the init Job is at best a no-op — its own guard
#    refuses to re-init on top of an existing backing (defense in depth
#    it already carries), but even with that guard this step wastes a
#    Pod, a Job slot, and operator time. Skip it and proceed straight
#    to the Deployment apply below.
if [ "${RESUME:-no}" = "yes" ]; then
  echo "RESUME path — skipping init Job (backing already present and validated by precheck)."
else
  kubectl apply -f gocryptfs-init-job.yaml
  kubectl wait --for=condition=complete job/gocryptfs-init-websitevolume --timeout=120s
  kubectl logs job/gocryptfs-init-websitevolume
fi

# 5. Apply the gocryptfs-enabled openemr Deployment. The first boot
#    of the first replica performs leader-election and writes
#    sqlconf.php, the admin user, and GACL rows INSIDE the
#    gocryptfs-decrypted view. Nothing ever lands on the backing NFS
#    as plaintext.
kubectl apply -f openemr-deployment-gocryptfs.yaml

# 6. Wait for first-boot to complete inside the encrypted mount.
#    Same two-phase readiness pattern as the migration path — Pod
#    Ready alone can fire on a follower; verify $config = 1 is
#    committed before considering the deployment seeded.
#
#    First wait for the Deployment's rollout to progress to the point
#    where its pods exist. `kubectl wait -l name=openemr pod` with
#    `--for=condition=Ready` snapshots the Pod set at invocation time
#    and returns immediately with "no matching resources found" if the
#    Deployment has not yet created a pod (the kube-controller-manager
#    may lag the `kubectl apply` by a second or two on a loaded
#    cluster). `rollout status` blocks on the Deployment's own status,
#    so it does not race pod creation.
kubectl rollout status deployment/openemr --timeout=1200s
kubectl wait --for=condition=Ready -l name=openemr pod --timeout=1200s
kubectl exec deploy/openemr -c openemr -- \
  sh -c 'grep -q "^\$config *= *1" /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'

# 7. (Optional) validate.
./validate-encryption.sh
```

**Known limitation.** This path is racy against very fast kubelet scheduling. If your cluster brings up openemr pods in milliseconds AND first-boot happens to not block on ganesha or mysql wait, step 1's `kubectl delete deployment` could arrive after the pod has already written sqlconf.php. The step 2 defensive check catches that case and tells you to switch to the migration path. In practice on the #910 stack, the mysql/redis init-container waits (plus ganesha mTLS handshake) give you minutes of headroom, so the race is comfortable — but DO rely on the precheck rather than assuming.

## What about rolling back?

Downgrading from this example back to the default stack means moving data out of the gocryptfs backing directory onto the plaintext NFS filesystem. The ordering is critical: the staged plaintext must be promoted to `websitevolume`'s root (where the default Deployment mounts) AND verified before the openemr Deployment is swapped back — otherwise openemr comes up seeing stale or missing site files.

```bash
# 1. Scale the gocryptfs-enabled openemr to 0, then verify quiescence.
#    Same two-step pattern as adoption: `kubectl wait --for=delete`
#    returns on the first termination event per Pod it snapshotted;
#    a slow-terminating Pod can still be present when the wait exits.
#    If ANY pod still holds `websitevolume` (e.g. stuck in Terminating
#    on a lingering mount, or a debug pod unrelated to the Deployment),
#    the rollback MUST abort — a running writer would race the
#    rsync-out step and we would stage a stale view.
#
#    Same PVC-mount probe as the migration path above: enumerate ALL
#    pods and filter by `.spec.volumes[*].persistentVolumeClaim.
#    claimName`. Label-scoped probes miss pods whose labels were
#    rotated; the PVC-mount signal is what actually matters. See the
#    migration-path probe comment above for the jsonpath-vs-awk
#    shape rationale.
#
#    COVERAGE note. This probe catches pods mounting the
#    websitevolume PVC in this namespace. It does NOT catch pods
#    with direct NFS volumeMounts bypassing the PVC, pods in other
#    namespaces that mount the same NFS share via their own PVCs,
#    or external NFS clients from outside the cluster. If your
#    topology is non-standard on any of those axes, verify
#    quiescence from THAT side before proceeding — a live writer
#    anywhere would race the rsync-out step and we would stage a
#    stale view.
#
#    Capture stderr separately so a kubectl API-call failure does
#    not fold onto stdout and get misread as a pod name.
#
#    Gate the quiescence probe on scale-to-0 SUCCESS. A `kubectl
#    scale` that errors out (API 4xx/5xx, insufficient RBAC,
#    Deployment-not-found) would otherwise let the probe run
#    unchanged — and the probe would vacuously report "no pods
#    mounting websitevolume" when the real state is "the Deployment
#    still has 1 replica but we failed to scale it, OR the
#    Deployment doesn't exist in this namespace and there never
#    were any pods to see." Either way, trusting the probe
#    post-scale-failure would advance the rollback against stale
#    knowledge of writer state. Abort immediately on scale failure.
if ! kubectl scale deployment openemr --replicas=0; then
  echo "ERROR: kubectl scale deployment/openemr --replicas=0 failed — aborting rollback."
  echo "The quiescence probe cannot run because we have not confirmed"
  echo "the Deployment's replica count went to 0. Investigate: did the"
  echo "Deployment ever exist (kubectl get deploy openemr)? Does the"
  echo "current context have RBAC for scale? Rerun this script once"
  echo "the scale command returns success."
  exit 1
fi
kubectl wait --for=delete pod -l name=openemr --timeout=120s || true
err_file=$(mktemp)
if ! probe=$(kubectl get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}' \
    2>"$err_file"); then
  echo "ERROR: kubectl get pods failed — cannot verify websitevolume is quiescent."
  cat "$err_file"
  rm -f "$err_file"
  exit 1
fi
rm -f "$err_file"
remaining=$(printf '%s\n' "$probe" | awk '
  NF >= 2 { for (i = 2; i <= NF; i++) if ($i == "websitevolume") { print $1; next } }
')
if [ -n "$remaining" ]; then
  echo "ERROR: pods still hold websitevolume after scale-to-0 + delete wait — aborting rollback:"
  echo "$remaining"
  exit 1
fi

# 2. Launch a privileged helper pod that mounts websitevolume,
#    gocryptfs-mounts the backing dir, rsyncs the decrypted view OUT
#    to a staging directory on websitevolume, verifies it, promotes it
#    to websitevolume's root (where the default stack's openemr
#    Deployment mounts), and only then deletes the gocryptfs backing
#    dir. Tailor the helper to your environment. The shape is:
#
#      mount websitevolume at /ws
#      gocryptfs -sharedstorage \
#        -passfile /etc/gocryptfs/passphrase \
#        /ws/gocryptfs-backing /dec
#      # Verify the FUSE mount succeeded BEFORE reading from /dec.
#      # If gocryptfs exited before mounting (bad passphrase, missing
#      # kernel module, etc.) the rsync below would see /dec as an
#      # empty directory on the pod rootfs and would then "copy out"
#      # nothing — proceeding to the backing-dir delete at the end
#      # would destroy the only remaining copy of the data. Abort on
#      # anything that isn't a live fuse/fuse.gocryptfs mount.
#      fs=$(awk '$2 == "/dec" { print $3 }' /proc/mounts | tail -1)
#      case "$fs" in
#        fuse|fuse.gocryptfs) echo "verified gocryptfs mount at /dec (type=$fs)" ;;
#        *) echo "ERROR: /dec is not a live FUSE mount (type='$fs') — aborting rollback"; exit 1 ;;
#      esac
#      mkdir -p /ws/.rollback-staging
#      rsync -aHAX /dec/ /ws/.rollback-staging/
#      # Verify counts and spot-check files BEFORE unmounting.
#      SRC_COUNT=$(find /dec -mindepth 1 -maxdepth 20 -type f | wc -l)
#      DST_COUNT=$(find /ws/.rollback-staging -mindepth 1 -maxdepth 20 \
#        -type f | wc -l)
#      [ "$SRC_COUNT" = "$DST_COUNT" ] || { echo "MISMATCH"; exit 1; }
#      fusermount3 -u /dec
#      # Promote staging → websitevolume root. Move the staged contents
#      # up one level so openemr's /sites mount sees them where it
#      # expects. Reconcile any leftover siblings of gocryptfs-backing/
#      # at /ws (there should be none after the adoption-step 3b
#      # cleanup, but defensively handle any that exist).
#      #
#      # Include hidden entries (shopt -s dotglob under bash, or the
#      # `.* *` pair pattern under /bin/sh). The sidecar's startup
#      # writes a `.gocryptfs-ready` marker INSIDE the decrypted view
#      # as the readiness signal, so the staged rsync tree WILL contain
#      # at least one dotfile. A plain `*` glob skips it, which means
#      # the subsequent `rmdir /ws/.rollback-staging` fails on a
#      # non-empty directory AND any genuine user dotfiles (e.g.
#      # `.htaccess`) get stranded in staging.
#      #
#      # Abort on the FIRST promotion failure. `rm -rf /ws/gocryptfs-
#      # backing` below is irreversible; if a promotion fails partway
#      # through (destination collision, mv I/O error, etc.) we must
#      # NOT delete the backing dir — it is still the only intact copy
#      # of the data. Set -e ensures each mv failure propagates; the
#      # `|| exit 1` on rmdir catches the "non-empty staging"
#      # post-condition explicitly.
#      set -e
#      # Enable dotglob so `*` matches hidden entries too (e.g.
#      # `.gocryptfs-ready`). With dotglob set, iterate `*` exactly
#      # ONCE — do NOT also iterate `.*`, or dotfiles would be
#      # processed twice and the second pass would hit the
#      # destination-collision guard on an entry the first pass
#      # already moved. (If your shell lacks dotglob — e.g. busybox
#      # ash — replace this block with an explicit dotfile pass
#      # that uses `.[!.]*` to avoid the self/parent refs.)
#      shopt -s dotglob || { echo "ERROR: shell lacks bash dotglob"; exit 1; }
#      for entry in /ws/.rollback-staging/*; do
#        base=$(basename "$entry")
#        # Skip the glob-no-match literal.
#        case "$base" in
#          '*') continue ;;
#          gocryptfs-backing) continue ;;
#        esac
#        if [ -e "/ws/$base" ]; then
#          echo "WARN: /ws/$base already exists — reconcile manually"
#          exit 1
#        fi
#        mv "$entry" "/ws/$base"
#      done
#      # rmdir is the fail-closed gate: if any promotion failed to move
#      # a file out of staging, this exits non-zero and the backing
#      # dir is preserved.
#      rmdir /ws/.rollback-staging || {
#        echo "ERROR: /ws/.rollback-staging not empty after promotion loop"
#        ls -la /ws/.rollback-staging
#        exit 1
#      }
#      # Only NOW remove the gocryptfs backing dir. Every promoted
#      # entry (including dotfiles) has landed at /ws/, and the
#      # staging dir has been successfully rmdir'd.
#      rm -rf /ws/gocryptfs-backing

# 3. Re-apply the default kubernetes/openemr/deployment.yaml. The
#    Deployment comes up pointing at the promoted plaintext contents.
kubectl apply -f ../../openemr/deployment.yaml
```

The reverse (plaintext NFS → gocryptfs) is the step-by-step adoption sequence above.

## Operational notes and known limitations

- **Encrypted-filename cardinality/size leak.** Operators (or attackers) with read access to the NFS backing can see how many files exist and how big each one is (modulo gocryptfs's small per-file header overhead), even though filenames and contents are encrypted. If this metadata leak is disqualifying for your threat model, Option 2a (LUKS) is the stronger metadata-hiding choice at the cost of single-replica.
- **FUSE performance characteristics.** Metadata operations (stat, readdir) go through userspace and are slower than kernel-ext4-over-NFS. For `sites/` workloads (per-request writes, occasional document uploads, cache reads), the overhead is in the single-digit percent range on typical workloads; it is NOT suitable as a general-purpose high-throughput shared filesystem. If you see unexpectedly high latency, profile with `gocryptfs -debug` enabled on a single pod outside the Deployment.
- **No growth planning required.** Unlike LUKS, gocryptfs does not pre-allocate a fixed-size container. Space usage grows as the plaintext would, plus a small per-file ciphertext header overhead (~a few bytes per file). The NFS backing PV's capacity constraints apply the same way they do to the default plaintext stack.
- **The backing NFS PV's capacity is shared across the gocryptfs backing directory plus `sslvolume` and `letsencryptvolume`.** See `kubernetes/README.md` § "Capacity caveat (shared backing PV)".
- **Backups must handle the backing directory as a tree, not a blob.** `kubectl cp` / `rsync` of `gocryptfs-backing/` is a valid backup — restoring it to a fresh PVC and applying this deployment with the same passphrase will mount it successfully. Tools that walk filesystem trees will see encrypted filenames (opaque identifiers) but can still enumerate and copy them.
- **Native-sidecar termination order** (the sidecar stops AFTER the main container on pod shutdown) is critical. The `restartPolicy: Always` initContainer pattern (the `SidecarContainers` feature) is **beta/default-on since Kubernetes 1.29** and **GA/locked since 1.33**. On 1.29..1.32 it works as documented as long as the `SidecarContainers` feature gate remains enabled on both the apiserver and every kubelet that may run this pod (the default); if a cluster admin has explicitly disabled the gate, the sidecar container will not be treated as a sidecar and the Deployment can get stuck during init. On Kubernetes older than 1.29, this pattern does not apply and the example needs adjustment (a plain sidecar container + shutdown hook).
- **Not tested with cluster upgrades that change the FUSE module.** FUSE is stable kernel surface but if an upgrade removes the module from the node image, the sidecar fails at mount time. Confirm FUSE availability on your node image before adopting.
- **Secret rotation requires a pod restart.** `gocryptfs -passwd` rewraps `gocryptfs.conf` immediately, but the sidecar re-reads the Secret only on pod start. Plan a rolling restart after rotation.

## File manifest

| File | Purpose |
|---|---|
| `README.md` | This document. |
| `gocryptfs-passphrase-secret.yaml` | Example Secret with a placeholder passphrase. Replace before use. |
| `gocryptfs-init-job.yaml` | One-shot Job that initializes the gocryptfs backing directory. Run once. Unprivileged. |
| `openemr-deployment-gocryptfs.yaml` | Modified openemr Deployment with privileged `gocryptfs-mounter` sidecar. 3 replicas retained; rollout strategy upgraded from the default's `Recreate` to `RollingUpdate`. |
| `validate-encryption.sh` | End-to-end validation script. Writes a plaintext marker through openemr's `/sites`, verifies `gocryptfs.conf` cipher + filename encryption, confirms no plaintext filenames leak into the raw backing, and head-samples every backing file for marker leakage. Set `VALIDATE_FULL=1` to additionally scan the full contents of every backing file. |
