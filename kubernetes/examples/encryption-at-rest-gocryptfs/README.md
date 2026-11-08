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
kubectl wait --for=delete pod -l name=openemr --timeout=120s

# 2. Create the gocryptfs passphrase Secret. In production, replace this
#    with an ESO-managed ExternalSecret.
#    EDIT the passphrase in gocryptfs-passphrase-secret.yaml FIRST.
kubectl apply -f gocryptfs-passphrase-secret.yaml

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
#       rsync -aHAX --exclude=gocryptfs-backing /ws/ /dec/
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
kubectl wait --for=delete pod -l name=openemr --timeout=120s || true

# 2. Defensive check: confirm no openemr pod ever reached
#    swarm-ready (i.e. no first-boot completed). If first-boot did
#    land, sqlconf.php is already on plaintext NFS and the greenfield
#    guarantee is lost — fall back to the migration path.
#
#    The simplest signal is the sqlconf.php file itself on
#    websitevolume. If it does NOT exist, no pod wrote it. We check
#    from a short-lived pod that mounts websitevolume read-only.
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: greenfield-precheck
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  - name: check
    image: alpine:3.24
    command: ["/bin/sh", "-c"]
    args:
      - |
        if [ -e /mnt/websitevolume/default/sqlconf.php ]; then
          echo "PLAINTEXT_SQLCONF_PRESENT: first-boot already landed on plaintext NFS"
          echo "Greenfield guarantee is lost. Use the migration path instead,"
          echo "or wipe websitevolume and start over."
          exit 1
        fi
        echo "PRECHECK_OK: no plaintext sqlconf.php found; greenfield path is viable"
    volumeMounts:
      - name: websitevolume
        mountPath: /mnt/websitevolume
        readOnly: true
  volumes:
    - name: websitevolume
      persistentVolumeClaim:
        claimName: websitevolume
EOF
kubectl wait --for=condition=Ready pod/greenfield-precheck --timeout=60s \
  || { kubectl logs pod/greenfield-precheck; kubectl delete pod greenfield-precheck; exit 1; }
# The pod exits 0 on PRECHECK_OK, 1 otherwise. A "Succeeded" phase
# means PRECHECK_OK; anything else means the check failed.
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/greenfield-precheck --timeout=60s \
  || { echo "Greenfield precheck FAILED — see pod logs above"; kubectl logs pod/greenfield-precheck; kubectl delete pod greenfield-precheck; exit 1; }
kubectl delete pod greenfield-precheck

# 3. Create the gocryptfs passphrase Secret.
kubectl apply -f gocryptfs-passphrase-secret.yaml

# 4. Run the one-shot init Job against the (empty) websitevolume.
#    This creates gocryptfs.conf + gocryptfs-backing/ WITHOUT any
#    plaintext content ever landing at the top level.
kubectl apply -f gocryptfs-init-job.yaml
kubectl wait --for=condition=complete job/gocryptfs-init-websitevolume --timeout=120s
kubectl logs job/gocryptfs-init-websitevolume

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
# 1. Scale the gocryptfs-enabled openemr to 0.
kubectl scale deployment openemr --replicas=0
kubectl wait --for=delete pod -l name=openemr --timeout=120s

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
#      shopt -s dotglob 2>/dev/null || true
#      for entry in /ws/.rollback-staging/* /ws/.rollback-staging/.*; do
#        base=$(basename "$entry")
#        # Skip the glob-no-match literals and the self/parent refs.
#        case "$base" in
#          '*'|'.*'|.|..) continue ;;
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
