# In-pod LUKS encryption-at-rest over NFS

This directory is an **example**, not a default. It demonstrates Option 2 of the two encryption-at-rest patterns outlined in `kubernetes/README.md` § **Production Hardening → Encryption at rest (storage layer)**:

- **Option 1 (default stack recommendation):** back the NFS server's PVC with an encrypted StorageClass (cloud KMS, Longhorn, Rook/Ceph). Simple, transparent, zero application change. Keys live with the storage layer / cloud KMS.
- **Option 2 (this example):** the openemr pod itself encrypts data with LUKS over the NFS mount, so keys never reach the NFS server pod and the NFS backing disk only ever sees ciphertext.

**Do not adopt this example unless you have a specific threat model that requires it.** Option 1 covers the overwhelming majority of HIPAA at-rest requirements with far less operational complexity. This example exists for users whose threat model treats the NFS server pod (or the storage layer under it) as untrusted.

> [!IMPORTANT]
> **This example downgrades openemr from 3 replicas to 1.**
>
> The default stack runs the openemr Deployment with `replicas: 3`. Adopting this example requires scaling that to `replicas: 1` for the duration — LUKS wraps a single ext4 filesystem that cannot be mounted read-write by two pods at once without corrupting it. If your availability model depends on multi-replica openemr, Option 1 (encrypted StorageClass) is the only in-tree answer today. See § **Multi-replica encryption-at-rest: what it would take** below for a fuller research treatment of why and what the alternatives look like.

## When to use this

Pick Option 2 (this example) when **any** of the following apply:

- You cannot trust the operator of the backing storage (third-party NFS appliance, shared storage cluster, multi-tenant storage) to never read the on-disk blocks.
- Your threat model treats a compromised `nfs-server` pod as in-scope. Option 1's encryption is only active between the backing block device and the NFS server pod — once data lands inside the NFS server's view of the filesystem, it is plaintext within that pod.
- Regulatory posture requires application-layer encryption with keys held in a KMS the storage operator cannot access.
- You are keeping the in-cluster NFS server (not swapping to EFS/Filestore/Azure Files) and want application-layer defense-in-depth beyond the stack's mTLS transit protection.

Pick Option 1 (default stack recommendation in `kubernetes/README.md`) when:

- You are on a hyperscaler and trust the cloud KMS / encrypted-disk model.
- You run OpenEMR with multiple replicas (Option 2 is single-writer; see below).
- You want the simplest operational model.

## Trade-offs: Option 1 vs Option 2

| Axis | Option 1 (encrypted StorageClass) | Option 2 (in-pod LUKS, this example) |
|---|---|---|
| **Where encryption happens** | Storage layer (below NFS server pod) | Application pod (openemr container, inside LUKS) |
| **NFS server pod sees** | Plaintext (decrypted by storage layer) | Ciphertext (LUKS container file) |
| **Key custody** | Cloud KMS / storage-layer key store | Kubernetes Secret, upgradable to ESO/Vault/KMS |
| **Replicas supported** | Any (RWX unchanged) | **1** (LUKS is single-writer; see below) |
| **Privilege required** | None beyond default | **Privileged sidecar** for `cryptsetup` + loop |
| **Operational complexity** | Low (one StorageClass edit) | Medium (one-shot format Job, sidecar, single-replica constraint) |
| **Protects against stolen disks** | Yes | Yes |
| **Protects against snapshot exfil** | Yes | Yes |
| **Protects against compromised NFS server pod** | No | **Yes** |
| **Protects against compromised openemr pod** | No | No (pod has the key in memory) |
| **Backup compatibility** | Standard (encrypted at rest, plaintext via snapshot restore + mount) | Backup must capture the LUKS container file as an opaque blob; restore requires the passphrase |
| **Key rotation** | Storage layer / cloud KMS native | Manual via `cryptsetup luksAddKey` / `luksRemoveKey` |

Options 1 and 2 are not mutually exclusive — running both in combination is valid defense-in-depth. The storage layer protects against physical disk theft and snapshot exfiltration; the in-pod LUKS layer additionally protects against a compromised NFS server pod.

## Single-writer constraint and the resolution this example picks

LUKS wraps a single filesystem image inside a container file. Two pods cannot mount the same ext4 filesystem read-write simultaneously — ext4 is not a clustered filesystem and the kernel does not coordinate journal writes across hosts. Attempting it corrupts the filesystem within seconds of concurrent writes.

Three possible resolutions, and why this example picks one of them:

1. **Single-replica openemr** (**this example's choice**). Set `replicas: 1`, keep the RWX NFS-backed PVC (now hosting one LUKS container file), and accept the availability trade-off. Chosen because:
   - It keeps the manifest topology closest to the default stack — reviewers can diff it cleanly.
   - It preserves the model where `websitevolume` holds all patient documents in one place.
   - Smaller OpenEMR deployments routinely run single-replica anyway; the HA story is in the MariaDB and Redis layers, not the application pod.
   - OpenEMR's first-boot leader election (see `startupProbe` comment in the default `deployment.yaml`) is a no-op with one replica, which simplifies boot.

2. **Per-replica LUKS files** (not chosen). Each replica could open its own LUKS container file (e.g. `.openemr-sites-$POD_NAME.luks`). This defeats the point of RWX — each pod has a private filesystem, so patient documents uploaded via one pod are invisible to the others. Rejected as it breaks OpenEMR's data model.

3. **Hybrid: encrypt only a non-shared subpath** (not chosen). Encrypt a leaf directory that genuinely doesn't need cross-pod sharing, leave the rest plaintext on NFS. OpenEMR's `sites/default/documents/` subtree is the obvious candidate — it holds PHI but is never written by multiple replicas simultaneously in normal operation. Rejected for the example because: (a) OpenEMR's upload code assumes POSIX semantics across the whole sites tree, so partitioning encrypted vs plaintext subpaths risks subtle write-visibility bugs; (b) "normal operation" is doing a lot of work — any admin batch job that walks `sites/` could race; (c) explaining which subpath is safe to encrypt vs not is more subtle than the manifests warrant for an example.

**If your threat model requires both encryption-at-rest AND multi-replica openemr, use Option 1 (encrypted StorageClass).** Option 2 as presented here is single-replica. A per-pod LUKS pattern or a clustered-filesystem-inside-LUKS pattern is possible but out of scope for this example.

## Multi-replica encryption-at-rest: what it would take

The single-replica constraint is a real downgrade from the default 3-replica openemr Deployment. We considered four approaches to lifting it; they all involve meaningfully more infrastructure or OpenEMR-side code than this example. Summary for operators deciding between "adopt this with single-replica" vs "wait for a multi-replica path":

| Approach | Multi-replica? | Infra addition | OpenEMR-side change | Status |
|---|---|---|---|---|
| **This example (LUKS + ext4)** | No | None beyond the sidecar | None | **Shipped** here |
| **Clustered FS inside LUKS** (GFS2 or OCFS2) | Yes | DLM, STONITH fencing, cluster membership manager | None | Out of scope |
| **FUSE transparent encryption** (`gocryptfs` shared-storage mode) | Yes | FUSE in-pod sidecar per replica | None | Candidate for a sibling example |
| **Application-layer encryption** (OpenEMR encrypts PHI at write) | Yes | KMS integration (Vault / cloud KMS) | **Significant** OpenEMR code change | Belongs in an OpenEMR RFC, not devops |

### Approach details

**Clustered FS inside LUKS.** The theoretical "just make ext4 multi-writer" answer: open the same LUKS mapper on every node, then layer GFS2 or OCFS2 on top of the decrypted device. Both filesystems are POSIX-cluster-aware and can safely coordinate writes across nodes — but only against a cluster manager that provides DLM (distributed lock manager) and STONITH-style fencing so a partitioned node can be reliably ejected before the surviving nodes keep writing. In practice: GFS2 comes from the RHEL/Fedora `dlm` + Pacemaker stack; OCFS2 ships with its own `o2cb` cluster. Either requires several operator components, node-level packages, a quorum model, and a fencing device that can actually power-off or network-isolate a sick node. Operationally this is a significant commitment (and most managed-Kubernetes distributions do not expose the node-level fencing primitives needed). We would be building and maintaining this just to encrypt PHI at rest, which Option 1 already achieves against the hyperscaler threat model. Not worth it for openemr-devops.

**FUSE transparent encryption.** `gocryptfs` is the realistic multi-replica alternative to LUKS. It stores each plaintext file as an individually-encrypted file in the backing directory (name-encrypted too), rather than encrypting an ext4 blob. In `-sharedstorage` mode, multiple clients can concurrently mount the same backing directory and see consistent decrypted views — concurrent writers are safe as long as they don't update the same file (which openemr replicas generally don't, by workload). The per-pod setup is comparable to this LUKS example: a privileged FUSE sidecar runs `gocryptfs` against the NFS-mounted directory and exposes the decrypted view via mount propagation. **Trade-offs** vs LUKS: per-file encryption (not full-filesystem), slightly slower cold reads, FUSE requires `/dev/fuse` + `SYS_ADMIN` in the sidecar, metadata operations are slower than kernel ext4. **This is the path we would recommend** for an openemr-devops operator who needs both encryption-at-rest and multi-replica openemr without touching OpenEMR code. It is *not* shipped as an example here because the design and validation are a separate piece of work — track it as a follow-up issue. If you need it today, use Option 1.

**Application-layer encryption.** The architecturally cleanest answer: OpenEMR itself encrypts PHI (documents, lab results, scanned forms) with keys from a KMS before writing to disk, and decrypts on read. Multi-replica becomes trivial because the on-disk format is ciphertext regardless of which pod wrote it, and the disk/NFS layer never sees plaintext. But this is an OpenEMR-core change — new `EncryptionService`, document-write/read interception points, key-rotation story, key-wrap for back-compat with existing unencrypted data — and lives in `openemr/openemr`, not `openemr/openemr-devops`. If this is your target, file it as an OpenEMR RFC; the infrastructure to support it (Vault secret, ESO wiring) is a few lines of YAML once the application side exists.

**Per-pod LUKS + central encrypted-document gateway** (rejected hybrid). A variant we considered: each openemr pod has its own ephemeral LUKS for `sites/` *scratch* state (session files, Smarty cache, temp uploads), and documents go through an in-cluster gateway that encrypts on write and stores in NFS. This combines the operational cost of LUKS with the design cost of a gateway service for no net simplification over the application-layer approach. Rejected.

### Recommendation

- **Need multi-replica + encryption-at-rest today**: use Option 1 (encrypted StorageClass). Covers HIPAA, zero extra ops.
- **Need application-layer encryption + multi-replica**: realistic path is a `gocryptfs` sibling example. File a follow-up issue in `openemr/openemr-devops` to design it; it borrows most of this example's shape (one-shot format step, privileged sidecar, mount propagation) and swaps the storage mechanism.
- **Need "PHI is ciphertext end-to-end including inside openemr's process memory"**: that requires application-layer encryption and lives in `openemr/openemr`, not in a devops example.

## Privilege / capability requirements

- **`luks-format-job.yaml`** — runs once per deployment lifetime. Requires `privileged: true` on the format container (needs `/dev/loop*`, `CAP_SYS_ADMIN`, access to `/dev/mapper`).
- **`openemr-deployment-luks.yaml`** — adds a `luks-opener` **sidecar** with `privileged: true`. The sidecar performs `cryptsetup luksOpen` + the `mount` call. It uses `mountPropagation: Bidirectional` so its mount reaches the host mount namespace.
- **The main `openemr` container is NOT privileged.** It mounts the shared `emptyDir` with `mountPropagation: HostToContainer`, so it inherits the sidecar's mount transparently without needing any elevated capability itself. This is a deliberate design: the openemr container runs user-supplied PHP, and widening its privilege would significantly weaken the application-layer trust boundary.

**Cluster prerequisites:**

- Nodes must have the `dm_crypt` kernel module available (standard on all modern Linux distros; present on Kind's default `kindest/node` image).
- The kubelet must allow privileged containers. This is the default; some hardened clusters disable it via PodSecurity admission — the LUKS example will not deploy there without an exception.
- PodSecurity admission: the namespace running this example needs to permit privileged containers (the `luks-opener` sidecar and the one-shot format Job both set `privileged: true`). Under PodSecurity Standards, only the `privileged` level allows that — `baseline` and `restricted` both reject privileged pods when **enforced**. PodSecurity Admission does *not* support per-pod exemption by label; the supported options are: (1) run the example in a namespace whose `pod-security.kubernetes.io/enforce` label is `privileged`; (2) have the cluster admin configure a PodSecurity-exempt `RuntimeClass` in the admission configuration file and set `runtimeClassName:` on these pods; or (3) leave enforcement off for the namespace (warn/audit only) and accept the warnings. The right option depends on your cluster's security posture — per-namespace is usually the simplest.

## Key management

This example uses a Kubernetes Secret (`luks-passphrase-secret.yaml`) with a placeholder passphrase. This is DEVELOPMENT ONLY — the passphrase in the file is publicly visible in this repo.

For production, treat the LUKS passphrase as a top-tier secret (loss = permanent data loss, exposure = encryption bypass) and upgrade the Secret to an external secret manager via **External Secrets Operator (ESO)**:

- **HashiCorp Vault:** `ExternalSecret` referencing a Vault KV path; ESO materializes the Kubernetes Secret.
- **AWS Secrets Manager:** `ExternalSecret` with IRSA-backed `SecretStore` to the secret ARN.
- **GCP Secret Manager:** `ExternalSecret` with Workload Identity to the secret resource.
- **Azure Key Vault:** `ExternalSecret` with Managed Identity to the secret.

In all four cases, the downstream manifests (`openemr-deployment-luks.yaml`, `luks-format-job.yaml`) consume the resulting Kubernetes Secret unchanged.

**Rotation is NOT as simple as rotating the Kubernetes Secret.** LUKS stores keys in the header's key slots on the container file itself — the sidecar reads the Secret only at pod start, and `cryptsetup luksOpen` consults the header's slots, not the Secret, to unlock. Updating the Secret alone leaves the old passphrase as the only working key.

The correct rotation sequence is:

1. Add the NEW passphrase to a free LUKS key slot against the existing LUKS file. Run this from a short-lived privileged helper pod that mounts `websitevolume`:

   ```bash
   cryptsetup luksAddKey /mnt/websitevolume/.openemr-sites.luks
   # interactively enter an EXISTING passphrase, then the NEW one
   ```

2. Update the Kubernetes Secret (`luks-passphrase`) to the NEW passphrase. If you are using ESO, rotate the upstream secret and let ESO materialize.

3. Restart the openemr pod. The sidecar re-reads the Secret on start and `luksOpen`s with the NEW passphrase (which the header now accepts).

4. Once the new pod is healthy, retire the OLD passphrase from the LUKS header, again from a privileged helper pod:

   ```bash
   cryptsetup luksRemoveKey /mnt/websitevolume/.openemr-sites.luks
   # interactively enter the OLD passphrase
   ```

**Hardware KMS integration** (CloudHSM, AWS KMS envelope encryption of the LUKS passphrase itself) is the next tier up — supported by cryptsetup via `--header` separation and tokens but out of scope for this example.

**Passphrase loss is irrecoverable.** LUKS has no escrow and no backdoor. Back the passphrase up in your organization's password escrow / KMS BEFORE running `luks-format-job.yaml`.

## Persistence semantics

- **The LUKS container file** (`.openemr-sites.luks` inside the NFS-backed `websitevolume`) is the durable artifact. It survives pod restarts, deployment rollouts, and cluster reboots as long as the PVC persists.
- **The `/dev/mapper/openemr-sites` device** and its mount into the pod are ephemeral. The `luks-opener` sidecar re-establishes them on every pod start by running `cryptsetup luksOpen` + `mount` against the file. Nothing LUKS-related survives a pod delete — which is correct, because the pod's view is the decrypted plaintext and that must not persist outside the pod.
- **The decrypted view** (`emptyDir`-backed shared mountpoint) is per-pod and per-replica. When the pod is deleted, Kubernetes wipes the `emptyDir`; the kernel's dm-crypt mapping stops existing on that node; and the only surviving artifact is the LUKS container file on NFS, which is ciphertext.

## Step-by-step adoption

Two paths are supported:

- **Migration from a running default-stack deployment** — openemr has already run first-boot on plaintext NFS; migrate the existing site contents into a freshly-formatted LUKS container. Simplest flow; the one the CI workflow exercises. **Caveat:** first-boot wrote `sqlconf.php` (containing the DB password) and the initial GACL rows to plaintext NFS. For deployments where even a historical plaintext snapshot of those credentials is disqualifying, use the greenfield path below.
- **Greenfield adoption (no plaintext first-boot)** — the LUKS container is created BEFORE openemr first-boot runs, so `sqlconf.php` and the demo seed land inside the LUKS filesystem from the beginning. More operationally tight (relies on racing kubelet to delete the default openemr Deployment before its pods boot) and gated by a defensive check that falls back to the migration path if that race is lost.

### Migration from a running default-stack deployment

Starting from a running #910 default stack:

```bash
# 0. Prerequisites: #910 default stack is up AND openemr has completed
#    first-boot. Verify:
kubectl get deployment openemr
kubectl get pvc websitevolume sslvolume letsencryptvolume

# 0a. If the luks-passphrase Secret is ALREADY present (e.g. an
#     operator provisioned it via External Secrets Operator ahead of
#     this migration), validate its shape BEFORE the destructive
#     scale-to-0 step below. A Secret with no `passphrase` key, or a
#     key that base64-decodes to empty / whitespace-only, would ride
#     through the Secret-adoption gate in step 2, then the format Job
#     would refuse at luksFormat time — by which point the running
#     deployment has already been scaled down and the migration is
#     half-committed. Fail fast here instead.
#
#     Only validate when the Secret is present; the Secret-adoption
#     gate in step 2 handles the absent case. Treat a kubectl API
#     error on the probe the same way the adoption gate does:
#     an indeterminate cluster state must not proceed to the
#     destructive scale-down.
# The published placeholder value (from luks-passphrase-secret.yaml).
# Treated as an unusable sentinel at every gate: the format Job refuses
# to run against it, and the destructive gates (pre-scale here, pre-
# adopt, pre-format, pre-resume) refuse to advance with it in place.
# Keep this in sync with the value shipped in the placeholder manifest.
LUKS_PLACEHOLDER_PASSPHRASE='example-development-passphrase-REPLACE-ME'
secret_probe_err=$(mktemp)
if kubectl get secret luks-passphrase -o name >/dev/null 2>"$secret_probe_err"; then
  passphrase_b64=$(kubectl get secret luks-passphrase \
                   -o jsonpath='{.data.passphrase}' 2>/dev/null || true)
  if [ -z "$passphrase_b64" ]; then
    echo "ERROR: Secret 'luks-passphrase' exists but has no 'passphrase' key."
    echo "       Refusing to scale openemr to 0 — fix the Secret shape first."
    rm -f "$secret_probe_err"
    exit 1
  fi
  decoded=$(printf '%s' "$passphrase_b64" | base64 -d 2>/dev/null || true)
  decoded_len=$(printf '%s' "$decoded" | tr -d '[:space:]' | wc -c | tr -d ' ')
  if [ "$decoded_len" = "0" ]; then
    echo "ERROR: Secret 'luks-passphrase' 'passphrase' key decodes to empty/whitespace."
    echo "       Refusing to scale openemr to 0 — fix the Secret value first."
    rm -f "$secret_probe_err"
    exit 1
  fi
  # Placeholder-rejection at the pre-scale gate. The format Job would
  # refuse against this value at luksFormat time, but by then the
  # deployment has already been scaled to 0 and the migration is half-
  # committed (the running openemr is gone; the LUKS container was never
  # formatted). Catching it here keeps the stack intact — the operator
  # fixes the Secret, re-runs this script, and the destructive scale-
  # down only ever happens against a Secret that will actually open the
  # container once formatted.
  if [ "$decoded" = "$LUKS_PLACEHOLDER_PASSPHRASE" ]; then
    echo "ERROR: Secret 'luks-passphrase' still carries the published placeholder value."
    echo "       Refusing to scale openemr to 0 — replace the placeholder first"
    echo "       (direct edit of the manifest, or let ESO materialize a real one)."
    rm -f "$secret_probe_err"
    exit 1
  fi
elif ! grep -qi 'NotFound\|not found' "$secret_probe_err"; then
  echo "ERROR: kubectl get secret luks-passphrase returned an API error that is NOT NotFound:"
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
# migration and the next boot inside LUKS would skip first-boot
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
# boot inside LUKS would then accept as "already configured" and
# skip setup, leaving the DB without the initial admin user.
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
# it observes per snapshotted Pod; a slow-terminating Pod can still
# be present when the wait returns. Follow up with a hard check that
# NO pod is still holding the `websitevolume` PVC open — if ANY
# remains, the migration MUST abort. A live writer during the
# rsync-in step corrupts the migration.
#
# Enumerate ALL pods in the namespace (no label selector) and inspect
# each one's `.spec.volumes[*].persistentVolumeClaim.claimName` for
# `websitevolume`. Label-scoped probes (`-l name=openemr`) miss
# writers whose labels were rotated — a canary with `track=canary`, a
# rename-in-place, or a one-off debug pod that mounted the PVC for
# a copy would all slip past. The PVC-mount signal is what we
# actually care about, so inspect it directly.
#
# NOTE on the jsonpath shape. The naive form
#   {range .items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=="websitevolume")]}
# expands an ARRAY on the left of ==; the behavior of that
# comparison is inconsistent across kubectl versions and jsonpath
# implementations. Use the robust form: print `<podName>
# <claimName1> ...` for every pod, then awk-filter rows whose
# second-or-later column equals websitevolume. Whole-field match,
# no substring collisions.
#
# COVERAGE note. This probe catches pods mounting the websitevolume
# PVC in this namespace. It does NOT catch pods with direct NFS
# volumeMounts bypassing the PVC, pods in other namespaces that
# mount the same NFS share via their own PVCs, or external NFS
# clients from outside the cluster. If your topology is non-standard
# on any of those axes, verify quiescence from THAT side before
# proceeding — a live writer anywhere would race the rsync-in step
# and corrupt the migration.
#
# Capture stderr separately so a kubectl API-call failure does not
# fold onto stdout and get misread as a pod name.
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
  echo "ERROR: pods still hold websitevolume after scale-to-0 + delete wait — aborting:"
  echo "$remaining"
  exit 1
fi

# 2. Create the LUKS passphrase Secret. In production, replace this with
#    an ESO-managed ExternalSecret.
#    EDIT the passphrase in luks-passphrase-secret.yaml FIRST.
#
# Apply the manifest ONLY when the Secret does not already exist in
# the target namespace — an unconditional `kubectl apply` would
# overwrite an ESO-managed Secret with the public placeholder, and the
# format Job would then refuse to run against it (its guard rejects
# the placeholder value). If ESO manages this Secret, do NOT apply
# the local manifest at all; let ESO own the lifecycle.
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
if kubectl get secret luks-passphrase -o name >/dev/null 2>"$secret_err"; then
  echo "Secret 'luks-passphrase' already exists — NOT applying the local manifest."
  existing=$(kubectl get secret luks-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
             | base64 -d 2>/dev/null || true)
  if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
    echo "WARNING: existing Secret still carries the published placeholder"
    echo "passphrase. The format Job will refuse to run against it."
  fi
elif grep -qi 'NotFound\|not found' "$secret_err"; then
  # Confirmed not found — create. `kubectl create` fails with
  # AlreadyExists on a concurrent ESO creation, which is the
  # correct outcome: we'd rather lose the race than overwrite.
  if ! kubectl create -f luks-passphrase-secret.yaml 2>"$secret_err"; then
    if grep -qi 'AlreadyExists\|already exists' "$secret_err"; then
      echo "Secret 'luks-passphrase' was created concurrently (likely by ESO) — NOT overwriting."
      existing=$(kubectl get secret luks-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
                 | base64 -d 2>/dev/null || true)
      if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
        echo "WARNING: concurrently-created Secret still carries the published"
        echo "placeholder passphrase. The format Job will refuse to run against it."
      fi
    else
      echo "ERROR: kubectl create secret luks-passphrase failed:"
      cat "$secret_err" >&2
      rm -f "$secret_err"
      exit 1
    fi
  fi
else
  echo "ERROR: kubectl get secret luks-passphrase returned an API error that is NOT NotFound:"
  cat "$secret_err" >&2
  echo "       Refusing to proceed — the cluster state is indeterminate."
  rm -f "$secret_err"
  exit 1
fi
rm -f "$secret_err"

# Post-adoption shape re-validation. Whichever branch ran above (adopted
# an ESO-managed Secret, created from the local manifest, or lost the
# AlreadyExists race), the Secret must now carry a non-empty passphrase
# before the format Job runs. A Secret created with a stringData key
# that whitespace-trims to zero, or an ESO template that materialized
# without a value yet, would ride through the branch above and only
# surface inside the format Job — after it has already started its
# privileged luksFormat. Re-read and fail fast here.
#
# The placeholder value is caught by the pre-scale gate above AND by the
# format Job's own guard; the earlier gate already prevents an operator
# from reaching this point with the placeholder in place. This gate adds
# the orthogonal "shape is wrong" axis (missing key, empty value, pure
# whitespace) that the placeholder check does not cover.
passphrase_b64=$(kubectl get secret luks-passphrase \
                 -o jsonpath='{.data.passphrase}' 2>/dev/null || true)
if [ -z "$passphrase_b64" ]; then
  echo "ERROR: Secret 'luks-passphrase' has no 'passphrase' key after the adoption step."
  echo "       Refusing to run the format Job — fix the Secret shape first."
  exit 1
fi
decoded_len=$(printf '%s' "$passphrase_b64" | base64 -d 2>/dev/null \
              | tr -d '[:space:]' | wc -c | tr -d ' ')
if [ "$decoded_len" = "0" ]; then
  echo "ERROR: Secret 'luks-passphrase' 'passphrase' key decodes to empty/whitespace."
  echo "       Refusing to run the format Job — fix the Secret value first."
  exit 1
fi

# 3. Run the one-shot format Job. This creates the LUKS container file
#    inside websitevolume. It takes a few minutes.
kubectl apply -f luks-format-job.yaml
kubectl wait --for=condition=complete job/luks-format-websitevolume --timeout=600s
kubectl logs job/luks-format-websitevolume

# 3b. MIGRATE existing plaintext sites contents INTO the LUKS filesystem.
#     The format Job only creates and formats the LUKS container file;
#     anything already on websitevolume (uploaded documents, site config,
#     cert material inside sites/default) is still plaintext beside the
#     LUKS file. After the Deployment swap (step 4), the main container
#     no longer mounts websitevolume directly — so without this step the
#     prior contents become stranded.
#
#     Run a short-lived privileged helper pod that mounts websitevolume,
#     luksOpens the fresh LUKS file, mounts the decrypted filesystem,
#     rsyncs the plaintext sites contents into the decrypted filesystem,
#     unmounts and luksCloses, then exits. Tailor this to your environment:
#     the shape is:
#
#       mount websitevolume at /ws
#       cryptsetup luksOpen --key-file /etc/luks/passphrase \
#         /ws/.openemr-sites.luks openemr-sites-migrate
#       mkdir -p /dec && mount /dev/mapper/openemr-sites-migrate /dec
#       rsync -aHAX --exclude=.openemr-sites.luks /ws/ /dec/
#       # (verify counts / spot-check files before proceeding)
#       umount /dec
#       cryptsetup luksClose openemr-sites-migrate
#
#     Only after verifying the copy, optionally delete the now-redundant
#     plaintext originals from /ws (everything except .openemr-sites.luks).
#     Leaving them in place is also valid — the main container will no
#     longer see them because it mounts the decrypted view, not
#     websitevolume — but the plaintext is still on NFS until removed.

# 4. Replace the default openemr Deployment with the LUKS-enabled one.
#    This REMOVES the existing openemr Deployment and creates the new
#    single-replica, LUKS-sidecar version.
kubectl delete deployment openemr
kubectl apply -f openemr-deployment-luks.yaml

# 5. Watch the pod come up. The luks-opener sidecar must become Ready
#    before the openemr container starts.
kubectl get pods -l name=openemr -w

# 6. (Optional) Validate that the encryption is actually effective.
#    Default run: LUKS header + AES-XTS cipher check + sampled (100 MiB)
#    plaintext-leakage scan. Fast.
./validate-encryption.sh

#    For paranoia-level coverage, set VALIDATE_FULL=1 to additionally
#    scan the *entire* LUKS container file (8 GiB+) for plaintext
#    leakage. Takes several minutes over NFS.
VALIDATE_FULL=1 ./validate-encryption.sh
```

> [!NOTE]
> The `validate-encryption.sh` scan (both the default sampled form and
> `VALIDATE_FULL=1`) only searches for the **test marker it just
> wrote**. A PASS proves that *this specific just-written write*
> ended up as ciphertext on NFS — which is the semantics we want to
> verify for the LUKS setup. It does **not** scan for arbitrary
> plaintext anywhere in the container, and in particular it does
> **not** detect plaintext originals left behind on `websitevolume`
> outside the LUKS file by an incomplete migration step. If you are
> concerned about stray plaintext from a prior setup, inspect
> `/mnt/websitevolume/` from inside the `luks-opener` sidecar after
> migration and confirm that only `.openemr-sites.luks` remains at
> the top level.

### Greenfield adoption (no plaintext first-boot)

Use this path when you need `sqlconf.php` (which carries the DB password) and the initial GACL seed to ONLY ever exist inside the LUKS filesystem — never as a plaintext file on `websitevolume`. The migration path above lets openemr first-boot land on plaintext NFS and then moves it under encryption afterwards; this path formats the LUKS container BEFORE openemr first-boot ever runs.

The sequence relies on racing kubelet: `kub-up` creates the default openemr Deployment, and a pod is scheduled immediately. You must delete the Deployment (and let the pod terminate) before its startup script writes `sqlconf.php`. In practice first-boot takes minutes to complete (leader-election + schema install + demo seed), so there is comfortable headroom, but you still need to act promptly and check that no pod has advanced past the swarm-ready marker.

```bash
# All commands run from the repository root unless noted otherwise.
# The one exception is step 3 onwards (manifests local to this
# example), which assume you have `cd`'d into the example directory
# first — that transition is marked inline below.
cd /path/to/openemr-devops   # replace with the clone's actual path

# 0. Bring up the default stack. This creates the mysql, redis,
#    ganesha-nfs, phpmyadmin, and openemr Deployments. openemr pods
#    begin first-boot immediately. Run from the repo root.
./kubernetes/kub-up

# 1. IMMEDIATELY delete the openemr Deployment before its pods
#    advance through first-boot. The `--ignore-not-found` allows
#    this to be idempotent if it ran during a kubelet gap.
kubectl delete deployment openemr --ignore-not-found
# Fail the setup if any old openemr writer pod survives the delete
# wait — proceeding past that point could race a still-finishing
# first-boot and land plaintext on NFS between the precheck and the
# LUKS format step.
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
#    NFS", which means the volume must be empty before the LUKS
#    container is formatted. Scoping the check to sqlconf.php alone
#    would miss uploaded documents, cert material, or any other
#    partially-landed state from a prior aborted first-boot (e.g. a
#    pod that wrote documents before being killed). Insist on an
#    empty volume, with a narrow carve-out for the LUKS init artifact
#    (.openemr-sites.luks) in case format already succeeded on a
#    prior attempt.
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
        #  - any entry besides the .openemr-sites.luks carve-out:
        #    exit 1 (EXISTING_DATA_PRESENT) — the greenfield
        #    guarantee is lost. Fall back to the migration path.
        #  - exactly the carve-out entry (.openemr-sites.luks alone,
        #    from a prior successful format): exit 0 — the greenfield
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
        saw_luks=0
        while IFS= read -r entry; do
          [ -z "$entry" ] && continue
          case "$entry" in
            # Carve-out: the LUKS format Job's artifact. If format
            # already ran (prior-attempt resume), the container file
            # is permitted at the top level — BUT its shape must match
            # what `cryptsetup luksFormat` produces and nothing else
            # (see the LUKS-header verification below).
            .openemr-sites.luks) saw_luks=1 ;;
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
          echo ".openemr-sites.luks from a prior-attempt format). Fall back"
          echo "to the migration path, or wipe websitevolume and retry."
          exit 1
        fi
        # Resume-path header check. The top-level allowlist let
        # .openemr-sites.luks through as a "prior format artifact",
        # but mere file existence is not enough: an OOM-killed format
        # Job, a half-written fallocate, a truncated restore from
        # backup, or an unrelated 8 GiB file plonked at that path
        # would all present as "file exists". `cryptsetup isLuks`
        # validates the on-disk LUKS header signature + version +
        # internal structure; it needs only read access and no
        # privileges. Any deviation means the format state is not
        # trustworthy and manual inspection is required BEFORE the
        # second format attempt reuses the file (which the format Job
        # refuses — leaving the operator wedged if the file is
        # invalid).
        #
        # NOTE: `isLuks` validates HEADER STRUCTURE only. It does NOT
        # verify the configured passphrase actually opens the
        # container. A valid LUKS header whose only keyslot wraps a
        # different passphrase will pass this check and fail at
        # `luksOpen` time inside the sidecar. If you are resuming
        # against a container formatted in a prior attempt and want
        # that stronger assurance before swapping the Deployment, run
        # the operator-side verify in the note immediately below.
        if [ "$saw_luks" = "1" ]; then
          if ! apk add --no-cache cryptsetup >/dev/null 2>&1; then
            echo "PRECHECK_UNKNOWN: failed to install cryptsetup for header check"
            exit 2
          fi
          if ! cryptsetup isLuks /mnt/websitevolume/.openemr-sites.luks; then
            echo "EXISTING_DATA_PRESENT: /mnt/websitevolume/.openemr-sites.luks is NOT a valid LUKS container."
            echo "A clean 'cryptsetup luksFormat' leaves a header that passes"
            echo "'cryptsetup isLuks'. This file does not — either the prior"
            echo "format Job did not complete (truncated / half-written), or"
            echo "the file is unrelated data at the same path. DO NOT resume"
            echo "— inspect manually. Typical recovery: if the file was"
            echo "written by a prior failed format attempt and no encrypted"
            echo "data has been committed yet, delete it (kubectl exec into"
            echo "any pod mounting websitevolume: rm /mnt/websitevolume/"
            echo ".openemr-sites.luks) and rerun the format Job."
            exit 1
          fi
          echo "PRECHECK_OK: RESUME — /mnt/websitevolume holds a well-formed LUKS container from a prior format; skip the format Job and proceed to Deployment apply"
          exit 0
        fi
        echo "PRECHECK_OK: EMPTY — /mnt/websitevolume is empty; proceed with the full greenfield sequence (format Job, then Deployment apply)"
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
#   0 — PRECHECK_OK (volume empty or only .openemr-sites.luks; proceed with greenfield)
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
  # paths: EMPTY (run the format Job) vs RESUME (a prior format already
  # produced a valid LUKS container at .openemr-sites.luks — the format
  # Job is at best redundant, and its own guard refuses to format on
  # top of an existing container). The precheck container's final log
  # line distinguishes the two (PRECHECK_OK: EMPTY vs PRECHECK_OK:
  # RESUME); capture the logs here BEFORE deleting the pod so the
  # signal survives.
  #
  # Fail-closed classification. The precheck container exited 0, but
  # exit 0 alone does not tell us WHICH of the two safe outcomes it
  # saw — only its log line does. `kubectl logs` can fail independently
  # of container exit (API glitch, pod GC race, authz on logs subresource)
  # and return an empty string under `|| true`. Branching on "RESUME
  # marker present → RESUME, everything else → EMPTY" would silently
  # route a log-read failure OR an unclassified marker through the
  # EMPTY arm — which runs the format Job, and the format Job's own
  # guard refuses to format on top of an existing container, so the
  # symptom would be a failed Job on a resume attempt. Classify three
  # ways explicitly: RESUME marker, EMPTY marker, or ABORT.
  PRECHECK_LOG_ERR=$(mktemp)
  PRECHECK_LOG=$(kubectl logs pod/greenfield-precheck 2>"$PRECHECK_LOG_ERR") || PRECHECK_LOG_FAILED=yes
  if [ "${PRECHECK_LOG_FAILED:-no}" = "yes" ]; then
    echo "ERROR: kubectl logs pod/greenfield-precheck failed — cannot classify precheck outcome."
    echo "       The container exited 0, but without its log line we cannot tell"
    echo "       EMPTY (run format Job) from RESUME (skip format Job). ABORTING."
    cat "$PRECHECK_LOG_ERR" >&2
    rm -f "$PRECHECK_LOG_ERR"
    kubectl delete pod greenfield-precheck --ignore-not-found
    exit 2
  fi
  rm -f "$PRECHECK_LOG_ERR"
  if printf '%s\n' "$PRECHECK_LOG" | grep -q '^PRECHECK_OK: RESUME'; then
    RESUME=yes
    echo "Greenfield precheck PASSED (RESUME) — websitevolume already holds a well-formed LUKS container from a prior format. The format Job will be SKIPPED below."
  elif printf '%s\n' "$PRECHECK_LOG" | grep -q '^PRECHECK_OK: EMPTY'; then
    RESUME=no
    echo "Greenfield precheck PASSED (EMPTY) — websitevolume is empty. The format Job will run below."
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
      echo "  - kubectl delete job luks-format-websitevolume --ignore-not-found"
      echo "  - If the luks-passphrase Secret came from this attempt"
      echo "    (i.e. you applied luks-passphrase-secret.yaml directly"
      echo "    in step 3 below): kubectl delete secret luks-passphrase"
      echo "    If it came from External Secrets Operator (ESO) or any other"
      echo "    controller-managed source: DO NOT delete it — let the"
      echo "    controller reconcile. Check for ESO ownership first:"
      echo "      kubectl get secret luks-passphrase -o jsonpath='{.metadata.ownerReferences}'"
      echo "    Non-empty ownerReferences (or an annotation like"
      echo "    'external-secrets.io/managed') means another controller owns it."
      echo "  - do NOT wipe websitevolume; migration needs the plaintext data"
      kubectl delete pod greenfield-precheck --ignore-not-found
      exit 1
      ;;
    2|"")
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

# Switch into the example directory for the manifests that follow.
# The remaining `kubectl apply -f <local-file>` references are
# resolved relative to THIS directory, not the repo root.
cd kubernetes/examples/encryption-at-rest-luks

# 3. Create the LUKS passphrase Secret.
#    EDIT the passphrase in luks-passphrase-secret.yaml FIRST before
#    applying. The committed value is a public placeholder and the
#    format Job below WILL REFUSE to run against it — leaving the
#    placeholder in the Secret is not a safety net, it's a dead end.
#    In production, provision this Secret via External Secrets
#    Operator (ESO) instead of applying the placeholder manifest at
#    all; see § Key management above.
#
#    RESUME WARNING. If the precheck accepted a pre-existing
#    .openemr-sites.luks (prior-attempt resume path), the passphrase
#    you put in this Secret MUST match the one used for the original
#    `cryptsetup luksFormat`. Each LUKS keyslot wraps the master key
#    with a specific passphrase; a new passphrase cannot open the
#    existing container, and applying a Secret with a rotated value
#    locks you out of anything already written through this
#    container. If you have lost the original passphrase, do NOT
#    resume — delete /mnt/websitevolume/.openemr-sites.luks on the
#    volume and start the format fresh (only safe when no encrypted
#    application data has been written through this container yet;
#    on a true greenfield that is always the case). Passphrase
#    ROTATION of an existing LUKS container is `cryptsetup
#    luksAddKey` + `cryptsetup luksRemoveKey` against the container
#    file, not a Secret edit — see § Secret rotation in the
#    operational notes.
#
#    OPTIONAL — operator-side luksOpen verify (resume path only).
#    The precheck above validated the LUKS HEADER with `isLuks`, but
#    did NOT verify the configured passphrase actually opens the
#    container (that would require a privileged pod + the Secret).
#    If this is a resume and you want end-to-end proof that the
#    Secret you are about to apply matches the container, run one
#    temporary privileged pod to perform a dry `luksOpen --test-
#    passphrase`:
#
#      kubectl apply -f luks-passphrase-secret.yaml
#      kubectl run luks-passphrase-verify --rm -i --restart=Never --image=alpine:3.24 --overrides='{"spec":{"containers":[{"name":"verify","image":"alpine:3.24","command":["sh","-c"],"args":["apk add --no-cache cryptsetup >/dev/null && cryptsetup luksOpen --test-passphrase --key-file /etc/luks/passphrase /mnt/websitevolume/.openemr-sites.luks && echo VERIFY_OK"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"websitevolume","mountPath":"/mnt/websitevolume","readOnly":true},{"name":"luks-passphrase","mountPath":"/etc/luks","readOnly":true}]}],"volumes":[{"name":"websitevolume","persistentVolumeClaim":{"claimName":"websitevolume"}},{"name":"luks-passphrase","secret":{"secretName":"luks-passphrase"}}]}}'
#
#    The `--overrides=` JSON is kept on a single line because
#    JSON string literals do not allow the shell-style
#    "\<newline>" continuation that the earlier multi-line form
#    used (that would make the payload invalid JSON — kubectl
#    would reject the overrides at parse time).
#
#    VERIFY_OK ⇒ the Secret opens the container; safe to proceed.
#    Any other output ⇒ passphrase mismatch; STOP. Rotating a Secret
#    whose value does not match the existing container header is
#    silent data loss waiting for the next pod restart.
#
# Apply the manifest ONLY when the Secret does not already exist in
# the target namespace. An unconditional `kubectl apply` would:
#   - overwrite an ESO-managed Secret with the public placeholder
#     (ESO will reconcile it back, but between those two events the
#     format Job may read the placeholder and refuse — or worse,
#     another pod may consume it);
#   - on the resume path, clobber the operator-set passphrase that
#     matches the existing on-disk LUKS header, which is silent data
#     loss waiting for the next pod restart.
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
if kubectl get secret luks-passphrase -o name >/dev/null 2>"$secret_err"; then
  echo "Secret 'luks-passphrase' already exists — NOT applying the local manifest."
  echo "If it is ESO-managed, this is the intended state. If it was left"
  echo "over from a prior run, verify its value matches the existing LUKS"
  echo "header (see the OPTIONAL luksOpen verify above) before continuing."
  # Sanity: if the existing Secret still carries the public placeholder,
  # surface that early — the format Job's guard will refuse to run, and
  # the operator should know BEFORE waiting on it to crash out.
  existing=$(kubectl get secret luks-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
             | base64 -d 2>/dev/null || true)
  if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
    # Rotation guidance differs between resume and fresh-init:
    #   RESUME=yes: the container was formatted with a specific
    #     passphrase, and each LUKS keyslot wraps the master key with
    #     THAT passphrase. Editing this Secret to a new value will NOT
    #     re-wrap any on-disk keyslot — it locks the operator out of
    #     everything already written through the container. The correct
    #     rotation is `cryptsetup luksAddKey` (new) + `luksRemoveKey`
    #     (old) against the container file first, then update the
    #     Secret to match.
    #   RESUME=no (fresh format): the format Job has not yet created a
    #     LUKS container, so there is no master key to protect. Editing
    #     the Secret BEFORE running the format Job is the correct move.
    if [ "${RESUME:-no}" = "yes" ]; then
      # ABORT on RESUME + placeholder. There is no safe forward path:
      # the existing container's LUKS keyslots wrap the master key with
      # whatever passphrase was used at format, and the placeholder
      # does not match any slot. Letting the setup continue (as a mere
      # warning) would apply the LUKS-enabled Deployment and the
      # sidecar would crashloop at every pod start against a Secret
      # that cannot open any keyslot. The operator must either add a
      # new passphrase to a free keyslot using the OLD passphrase
      # (`cryptsetup luksAddKey` + `luksRemoveKey`) and then update
      # the Secret — or, if the old passphrase is lost, see the
      # multi-slot / header-backup recovery notes in § Key management.
      echo "ERROR: existing Secret still carries the published placeholder"
      echo "       passphrase, AND the precheck selected the RESUME path."
      echo "       There is no safe recovery from here — refusing to continue."
      echo ""
      echo "       The existing container's LUKS keyslots wrap the master key"
      echo "       with whatever passphrase was used at format; the placeholder"
      echo "       does not match any slot, and a new Secret value cannot open"
      echo "       any slot without that old passphrase."
      echo ""
      echo "       To recover, rotate the container FIRST:"
      echo "         * run \`cryptsetup luksAddKey\` (new passphrase) then"
      echo "           \`cryptsetup luksRemoveKey\` (old passphrase) against"
      echo "           /mnt/websitevolume/.openemr-sites.luks from a privileged"
      echo "           helper pod; THEN"
      echo "         * update this Secret to the new passphrase."
      echo "       See § Key management for the multi-slot / header-backup"
      echo "       recovery path if the old passphrase is lost."
      exit 1
    else
      echo "WARNING: existing Secret still carries the published placeholder"
      echo "passphrase. The format Job will refuse to run against it. Replace"
      echo "the value BEFORE running the format Job (direct edit, or let ESO"
      echo "reconcile a real one)."
    fi
  fi
elif grep -qi 'NotFound\|not found' "$secret_err"; then
  if ! kubectl create -f luks-passphrase-secret.yaml 2>"$secret_err"; then
    if grep -qi 'AlreadyExists\|already exists' "$secret_err"; then
      echo "Secret 'luks-passphrase' was created concurrently (likely by ESO) — NOT overwriting."
      existing=$(kubectl get secret luks-passphrase -o jsonpath='{.data.passphrase}' 2>/dev/null \
                 | base64 -d 2>/dev/null || true)
      if [ "$existing" = 'example-development-passphrase-REPLACE-ME' ]; then
        if [ "${RESUME:-no}" = "yes" ]; then
          # ABORT on RESUME + placeholder (same reasoning as the
          # existing-Secret branch above). No safe forward path.
          echo "ERROR: concurrently-created Secret still carries the published"
          echo "       placeholder, AND the precheck selected the RESUME path."
          echo "       There is no safe recovery from here — refusing to continue."
          echo "       Rotate the container via \`cryptsetup luksAddKey\` +"
          echo "       \`luksRemoveKey\` first (see the existing-Secret branch"
          echo "       above for the full sequence)."
          rm -f "$secret_err"
          exit 1
        else
          echo "WARNING: concurrently-created Secret still carries the published"
          echo "placeholder passphrase. The format Job will refuse to run against it."
        fi
      fi
    else
      echo "ERROR: kubectl create secret luks-passphrase failed:"
      cat "$secret_err" >&2
      rm -f "$secret_err"
      exit 1
    fi
  fi
else
  echo "ERROR: kubectl get secret luks-passphrase returned an API error that is NOT NotFound:"
  cat "$secret_err" >&2
  echo "       Refusing to proceed — the cluster state is indeterminate."
  rm -f "$secret_err"
  exit 1
fi
rm -f "$secret_err"

# Post-adoption shape re-validation. Whichever branch ran above (adopted
# an ESO-managed Secret, created from the local manifest, or lost the
# AlreadyExists race), the Secret must now carry a non-empty passphrase
# before anything consumes it — on the non-RESUME path that is the
# format Job's privileged luksFormat; on the RESUME path it is the
# Deployment apply below, where the luks-opener sidecar would then fail
# at pod start. Either way, a missing key / empty value / whitespace-
# only value surfaces as a hard-to-diagnose luksOpen failure instead of
# a clean error here.
#
# The placeholder value is caught by the branch above and (for
# non-RESUME) by the format Job's own guard. This gate adds the
# orthogonal "shape is wrong" axis that the placeholder check does not
# cover.
passphrase_b64=$(kubectl get secret luks-passphrase \
                 -o jsonpath='{.data.passphrase}' 2>/dev/null || true)
if [ -z "$passphrase_b64" ]; then
  echo "ERROR: Secret 'luks-passphrase' has no 'passphrase' key after the adoption step."
  echo "       Refusing to proceed — fix the Secret shape first."
  exit 1
fi
decoded_len=$(printf '%s' "$passphrase_b64" | base64 -d 2>/dev/null \
              | tr -d '[:space:]' | wc -c | tr -d ' ')
if [ "$decoded_len" = "0" ]; then
  echo "ERROR: Secret 'luks-passphrase' 'passphrase' key decodes to empty/whitespace."
  echo "       Refusing to proceed — fix the Secret value first."
  exit 1
fi

# 4. Run the one-shot format Job against the (empty) websitevolume.
#    This creates the LUKS container file WITHOUT any plaintext
#    content ever landing beside it.
#
#    RESUME path: if the precheck above set RESUME=yes, the volume
#    already holds a well-formed .openemr-sites.luks from a prior
#    format and re-running the format Job is at best a no-op — its own
#    guard refuses to format on top of an existing container (defense
#    in depth it already carries), but even with that guard this step
#    wastes a Pod, a Job slot, and operator time. Skip it and proceed
#    straight to the Deployment apply below.
if [ "${RESUME:-no}" = "yes" ]; then
  echo "RESUME path — skipping format Job (container already present and validated by precheck)."
else
  kubectl apply -f luks-format-job.yaml
  kubectl wait --for=condition=complete job/luks-format-websitevolume --timeout=600s
  kubectl logs job/luks-format-websitevolume
fi

# 5. Apply the LUKS-enabled openemr Deployment. The first boot of the
#    pod performs leader-election and writes sqlconf.php, the admin
#    user, and GACL rows INSIDE the decrypted LUKS filesystem.
#    Nothing ever lands on the backing NFS as plaintext.
kubectl apply -f openemr-deployment-luks.yaml

# 6. Wait for first-boot to complete inside the encrypted mount.
#    Same two-phase readiness pattern as the migration path — Pod
#    Ready alone can fire while setup is still underway; verify
#    $config = 1 is committed before considering the deployment
#    seeded.
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

Downgrading from this example back to the default stack means moving data out of the LUKS container file onto the plaintext NFS filesystem.

```bash
# 1. Scale the LUKS-enabled openemr to 0, then verify quiescence.
#    Same two-step pattern as adoption: `kubectl wait --for=delete`
#    returns on the first termination event per snapshotted Pod; a
#    slow-terminating Pod can still be present when the wait returns.
#    If ANY pod still holds `websitevolume` (stuck in Terminating on
#    a lingering mount, or a debug pod unrelated to the Deployment),
#    the rollback MUST abort — a running writer would race the
#    rsync-out step and we would stage a stale view.
#
#    PVC-mount probe (not a label probe): enumerate ALL pods and
#    filter by `.spec.volumes[*].persistentVolumeClaim.claimName`.
#    Label-scoped probes miss pods whose labels were rotated. See
#    the migration-path probe comment above for the jsonpath-vs-awk
#    shape rationale.
#
#    COVERAGE note. This probe catches pods mounting the
#    websitevolume PVC in this namespace. It does NOT catch pods
#    with direct NFS volumeMounts bypassing the PVC, pods in other
#    namespaces that mount the same NFS share via their own PVCs,
#    or external NFS clients from outside the cluster. If your
#    topology is non-standard on any of those axes, verify
#    quiescence from THAT side before proceeding.
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

# 2. Launch a privileged helper pod that opens the LUKS file, mounts it,
#    and copies the contents OUT to a plaintext location. This is a
#    manual operation — tailor the helper to your environment. The
#    shape is: mount websitevolume, luksOpen the container file, mount
#    the decrypted filesystem, rsync its contents to a staging dir,
#    then wipe the LUKS file.

# 3. Re-apply the default kubernetes/openemr/deployment.yaml.
kubectl apply -f ../../openemr/deployment.yaml
```

The reverse (plaintext NFS → LUKS) is the step-by-step adoption sequence above, except that step 3's format Job needs to run against a `websitevolume` that is NOT empty. Pre-copy the existing plaintext sites contents into a scratch location, format into the LUKS file, mount, copy back.

## Operational hardening (production prerequisite)

The manifests ship with `apk add --no-cache cryptsetup e2fsprogs util-linux` at container start in both the `luks-opener` sidecar (`openemr-deployment-luks.yaml`) and the one-shot format Job (`luks-format-job.yaml`). This is deliberate for an example — the manifests are self-contained and copy-pasteable against a stock `alpine:3.20` image — but it has two production-visible costs:

1. **Startup latency and Alpine-repository dependency on every pod start.** Each new sidecar start re-downloads the three packages from Alpine's repositories. A cluster that cannot reach `dl-cdn.alpinelinux.org` (air-gapped, egress-firewalled) cannot start the LUKS sidecar, so the openemr pod never becomes ready.
2. **Unpinned package versions.** `apk add` resolves whatever the Alpine repo currently serves, which drifts over time and can be yanked. A repro-build guarantee requires pinning the tools.

**Before adopting this example in production**, bake a pinned image that already contains `cryptsetup`, `e2fsprogs`, and `util-linux`:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache cryptsetup e2fsprogs util-linux
```

Push it to your own registry, pin by digest, and point BOTH the `luks-opener` sidecar's `image:` field AND the format Job's `image:` field at that pinned digest. Then strip the `apk add` line from both container command scripts. Using the same image for both keeps the tool versions in lockstep between format time and open time.

## Operational notes and known limitations

- **LUKS container file size is fixed at format time.** The `luks-format-job.yaml` pre-allocates 8 GiB by default (configurable via `CONTAINER_SIZE`). Growing it later is possible but manual: grow the file with `fallocate`, `cryptsetup resize`, `resize2fs` — done against a stopped openemr pod.
- **The backing NFS PV's capacity is shared across the LUKS file plus `sslvolume` and `letsencryptvolume`.** See `kubernetes/README.md` § "Capacity caveat (shared backing PV)". Size the LUKS container file with that budget in mind.
- **Backups must handle the LUKS file as an opaque blob.** `kubectl cp` or `rsync` of `.openemr-sites.luks` is a valid backup — restoring it to a fresh PVC and applying this deployment with the same passphrase will mount it successfully. Tools that walk filesystem trees expecting to see patient documents will see only the LUKS file and nothing to walk into.
- **Native-sidecar termination order** (the sidecar stops AFTER the main container on pod shutdown) is critical. This requires Kubernetes 1.29+ for the `restartPolicy: Always` initContainer semantics to be GA. On older clusters, the pattern needs adjustment (a true sidecar container plus a shutdown hook, or an external PreStop hook).
- **Not tested with cluster upgrades that change the kernel major version.** `dm-crypt` is stable kernel surface but if an upgrade removes the module from the node image, the sidecar fails on `luksOpen`. Confirm `dm_crypt` availability on your node image before adopting.
- **Secret rotation requires a pod restart.** `cryptsetup luksAddKey` / `luksRemoveKey` must run against the LUKS header on the NFS file; the sidecar re-reads the Secret only on pod start. Plan a maintenance window for passphrase rotation — the openemr Deployment is already single-replica, so this is downtime, not a rolling update.

## File manifest

| File | Purpose |
|---|---|
| `README.md` | This document. |
| `luks-passphrase-secret.yaml` | Example Secret with a placeholder passphrase. Replace before use. |
| `luks-format-job.yaml` | One-shot Job that creates and formats the LUKS container file. Run once. |
| `openemr-deployment-luks.yaml` | Modified openemr Deployment with privileged `luks-opener` sidecar and single replica. |
| `validate-encryption.sh` | End-to-end validation script. Writes a plaintext marker through openemr's `/sites`, verifies the LUKS header + AES-XTS cipher via `cryptsetup`, and scans the first 100 MiB of the raw file for leakage. Set `VALIDATE_FULL=1` to additionally scan the entire multi-GiB blob. |
