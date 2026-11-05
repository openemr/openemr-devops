# In-pod LUKS encryption-at-rest over NFS

This directory is an **example**, not a default. It demonstrates Option 2 of the two encryption-at-rest patterns outlined in `kubernetes/README.md` § **Production Hardening → Encryption at rest (storage layer)**:

- **Option 1 (default stack recommendation):** back the NFS server's PVC with an encrypted StorageClass (cloud KMS, Longhorn, Rook/Ceph). Simple, transparent, zero application change. Keys live with the storage layer / cloud KMS.
- **Option 2 (this example):** the openemr pod itself encrypts data with LUKS over the NFS mount, so keys never reach the NFS server pod and the NFS backing disk only ever sees ciphertext.

**Do not adopt this example unless you have a specific threat model that requires it.** Option 1 covers the overwhelming majority of HIPAA at-rest requirements with far less operational complexity. This example exists for users whose threat model treats the NFS server pod (or the storage layer under it) as untrusted.

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

## Privilege / capability requirements

- **`luks-format-job.yaml`** — runs once per deployment lifetime. Requires `privileged: true` on the format container (needs `/dev/loop*`, `CAP_SYS_ADMIN`, access to `/dev/mapper`).
- **`openemr-deployment-luks.yaml`** — adds a `luks-opener` **sidecar** with `privileged: true`. The sidecar performs `cryptsetup luksOpen` + the `mount` call. It uses `mountPropagation: Bidirectional` so its mount reaches the host mount namespace.
- **The main `openemr` container is NOT privileged.** It mounts the shared `emptyDir` with `mountPropagation: HostToContainer`, so it inherits the sidecar's mount transparently without needing any elevated capability itself. This is a deliberate design: the openemr container runs user-supplied PHP, and widening its privilege would significantly weaken the application-layer trust boundary.

**Cluster prerequisites:**

- Nodes must have the `dm_crypt` kernel module available (standard on all modern Linux distros; present on Kind's default `kindest/node` image).
- The kubelet must allow privileged containers. This is the default; some hardened clusters disable it via PodSecurity admission — the LUKS example will not deploy there without an exception.
- PodSecurity admission: the namespace running this example needs to permit privileged containers (the `luks-opener` sidecar and the one-shot format Job both set `privileged: true`). Under PodSecurity Standards, only the `privileged` level allows that — `baseline` and `restricted` both reject privileged pods when **enforced**. Options: run the example in a namespace labeled `pod-security.kubernetes.io/enforce=privileged`; apply the same label only to the pods matching this example via a per-pod exemption; or leave enforcement off (warn/audit only) for the namespace and accept the warnings.

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

Starting from a running #910 default stack:

```bash
# 0. Prerequisites: #910 default stack is up. Verify:
kubectl get deployment openemr
kubectl get pvc websitevolume sslvolume letsencryptvolume

# 1. Scale openemr to 0 so no pod is holding websitevolume open.
kubectl scale deployment openemr --replicas=0
kubectl wait --for=delete pod -l name=openemr --timeout=120s

# 2. Create the LUKS passphrase Secret. In production, replace this with
#    an ESO-managed ExternalSecret.
#    EDIT the passphrase in luks-passphrase-secret.yaml FIRST.
kubectl apply -f luks-passphrase-secret.yaml

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
./validate-encryption.sh
```

## What about rolling back?

Downgrading from this example back to the default stack means moving data out of the LUKS container file onto the plaintext NFS filesystem.

```bash
# 1. Scale the LUKS-enabled openemr to 0.
kubectl scale deployment openemr --replicas=0
kubectl wait --for=delete pod -l name=openemr --timeout=120s

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
| `validate-encryption.sh` | Interactive recipe that proves plaintext written through the openemr pod is ciphertext on the NFS backing. |
