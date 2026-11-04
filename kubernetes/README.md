# Overview

This Kubernetes deployment serves two related goals:

1. **A working starting point.** A complete, runnable OpenEMR environment on Kubernetes — usable on Kind for local development and adaptable for production deployments on EKS, GKE, AKS, or on-prem clusters.
2. **A reference for secure distributed deployments.** The stack demonstrates the security primitives (mTLS with X509 client certificate verification, encrypted MariaDB replication, Redis Sentinel with mTLS) needed when OpenEMR components may be installed across trust boundaries — different clusters, different VPCs, or communicating over the public internet.

Which lens you read this through affects what's essential vs. defense-in-depth:

- **Single-cluster production users** (one EKS/GKE/AKS cluster on modern hyperscaler hardware): the cloud provider's transparent infrastructure encryption already covers wire confidentiality between nodes. The mTLS layers in this stack are then defense-in-depth and provide endpoint authentication; see "Security Architecture" for what each layer adds and "Connection Security" for downgrade paths.
- **Distributed deployment users** (components separated across networks or trust boundaries): the mTLS layers are load-bearing — they're the only thing protecting and authenticating connections that cross untrusted networks. Don't disable them.

This solution requires OpenEMR Docker 8.2.0 or higher. The flex Docker series is also supported for development purposes (change to `openemr/openemr:flex` in `openemr/deployment.yaml`, though startup will be significantly slower as each instance builds from source). While not a fully hardened production deployment, this provides a solid working foundation with mTLS encryption, Redis Sentinel failover, and multi-node support, and should open the door to a myriad of other Kubernetes-based solutions.

OpenEMR Kubernetes orchestration. Orchestration includes OpenEMR, MariaDB, Redis, and phpMyAdmin.
  - **OpenEMR** - 3 deployment replications of OpenEMR are created. Replications can be increased/decreased. Ports for both http and https.
  - **MariaDB** - 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created. Replications can be increased/decreased which will increase/decrease number of replica/slaves. Connections use mTLS (mutual TLS / X509 client certificate verification) by default, including replication traffic. See **Security Architecture → MariaDB connections** for what this protects and **Connection Security → MariaDB Connection Security** for how to downgrade to TLS-only or plain TCP.
  - **Redis** - Configured to support failover. There is 1 master and 2 slaves (no read access on slaves) for a statefulset and 3 sentinels for another statefulset. OpenEMR connects directly to Redis with mTLS (mutual TLS / X509 client certificate verification) by default. The primary/slaves and sentinels would require script changes if wish to increase/decrease replicates for these since these are hard-coded several places in the scripts. There are 3 users/passwords (`default`, `replication`, `admin`) used in this redis scheme. All passwords are stored in the `redis-credentials` Kubernetes Secret (redis/secret.yaml) and should be changed for production use. The `default` is the typical worker/app/client user. See **Security Architecture → Redis connections** for details and **Connection Security → Redis Connection Security** for how to downgrade.
  - **phpMyAdmin** - There is 1 deployment instance of phpMyAdmin. Access is via `kubectl port-forward` only (not exposed externally).

# Use

> **Not supported in LXC system containers** (including the [Claude Appliance](https://github.com/openemr/openemr/blob/master/Documentation/contributors/claude-appliance-setup.md), Proxmox LXC, Incus system containers). LXC's default seccomp profile blocks `open_by_handle_at` as part of its container-escape mitigation, which breaks the in-cluster NFS server (nfs-ganesha's FSAL_VFS uses `open_by_handle_at` for handle-based filesystem access). The LXC config can be edited to lift the block, but doing so weakens LXC's isolation in a way that's load-bearing in the container's threat model. Use a bare host, a VM (Incus VM, cloud VM, etc.), or a laptop for local Kind-based development instead.

1. Install Kind. Other Kubernetes distributions can be substituted by users familiar with their networking and storage models, but the instructions below assume Kind.
    - For Kind, see below for instructions sets with 1 node or 4 nodes.
        - 1 node:
            ```bash
            kind create cluster --config kind-config-1-node.yaml
            ```
        - 4 nodes (1 control-plane node and 3 worker nodes). Shared volumes use an in-cluster NFS server + CSI driver (deployed by kub-up) with mTLS wrapping, so pods on different nodes can share ReadWriteMany volumes:
            ```bash
            kind create cluster --config kind-config-4-nodes.yaml
            ```
            - After you run the kub-up command below, here is a neat command to show which nodes the pods are in
                ```bash
                kubectl get pod -o wide
                ```
2. To start OpenEMR orchestration:
    ```bash
    bash kub-up
    ```
3. Can see overall progress with following command:
    ```bash
    kubectl get all
    ```
      - It will look something like this when completed:
          ```console
          NAME                                   READY   STATUS    RESTARTS   AGE
          pod/mysql-sts-0                        1/1     Running   0          111s
          pod/mysql-sts-1                        1/1     Running   0          91s
          pod/nfs-server-74f8d9c7b5-xxxxx        2/2     Running   0          3m
          pod/nfs-stunnel-client-abcde           1/1     Running   0          3m
          pod/openemr-7889cf48d8-9jdfl           1/1     Running   0          111s
          pod/openemr-7889cf48d8-qphrw           1/1     Running   0          111s
          pod/openemr-7889cf48d8-zlx9f           1/1     Running   0          111s
          pod/phpmyadmin-f4d9bfc69-rx82d         1/1     Running   0          111s
          pod/redis-0                            1/1     Running   0          111s
          pod/redis-1                            1/1     Running   0          77s
          pod/redis-2                            1/1     Running   0          55s
          pod/sentinel-0                         1/1     Running   0          111s
          pod/sentinel-1                         1/1     Running   0          34s
          pod/sentinel-2                         1/1     Running   0          30s

          NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                        AGE
          service/kubernetes   ClusterIP   10.96.0.1      <none>        443/TCP                        3m40s
          service/mysql        ClusterIP   None           <none>        3306/TCP                       111s
          service/nfs-server   ClusterIP   10.96.1.73     <none>        20490/TCP                      3m
          service/openemr      NodePort    10.96.6.51     <none>        8080:30080/TCP,8090:30443/TCP   111s
          service/phpmyadmin   ClusterIP   10.96.64.163   <none>        8081/TCP,8091/TCP              111s
          service/redis        ClusterIP   None           <none>        6379/TCP                       111s
          service/sentinel     ClusterIP   None           <none>        26379/TCP                      111s

          NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
          deployment.apps/nfs-server   1/1     1            1           3m
          deployment.apps/openemr      3/3     3            3           111s
          deployment.apps/phpmyadmin   1/1     1            1           111s

          NAME                                READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
          daemonset.apps/nfs-stunnel-client   1       1            1           <none>          3m

          NAME                                    DESIRED   CURRENT   READY   AGE
          replicaset.apps/nfs-server-74f8d9c7b5   1         1         1       3m
          replicaset.apps/openemr-7889cf48d8      3         3         3       111s
          replicaset.apps/phpmyadmin-f4d9bfc69    1         1         1       111s

          NAME                         READY   AGE
          statefulset.apps/mysql-sts   2/2     111s
          statefulset.apps/redis       3/3     111s
          statefulset.apps/sentinel    3/3     111s
          ```

          Note: `csi-driver-nfs` controller + node daemonset pods run in
          the `kube-system` namespace (not shown here). Use
          `kubectl get pods -n kube-system -l 'app in (csi-nfs-controller,csi-nfs-node)'`
          to see them.
4. Getting the url link to OpenEMR:
    - With the provided Kind config files, OpenEMR is mapped to localhost: `http://localhost:8800` or `https://localhost:9800`
5. Accessing phpMyAdmin:
    - phpMyAdmin is not exposed externally for security. Access it via port-forward:
        ```bash
        kubectl port-forward service/phpmyadmin 8081:8081
        ```
        Then navigate to `http://localhost:8081`. Press `Ctrl+C` to stop the port-forward when done.
6. Some cool replicas stuff with OpenEMR. The OpenEMR docker pods are run as a replica set (since it is set to 3 replicas in this OpenEMR deployment script). Gonna cover how to view the replica set and how to change the number of replicas on the fly in this step.
    - First. lets list the replica set like this:
        ```bash
        kubectl get rs
        ```
        - It will look something like this (note OpenEMR has 3 desired and 3 current replicas going):
            ```console
            NAME                    DESIRED   CURRENT   READY   AGE
            nfs-server-74f8d9c7b5   1         1         1       11m
            openemr-7889cf48d8      3         3         3       9m22s
            phpmyadmin-f4d9bfc69    1         1         1       9m22s
            ```
    - Second, lets increase OpenEMR's replicas from 3 to 10 (ie. pretend in an environment where a huge number of OpenEMR users are using the system at the same time)
        ```bash
        kubectl scale deployment.apps/openemr --replicas=10
        ```
        - It will return the following:
            ```console
            deployment.apps/openemr scaled
            ```
        - Now, there are 10 replicas of OpenEMR instead of 3. Enter the `kubectl get rs` and `kubectl get pod` to see what happened.
    - Third, lets decrease OpenEMR's replicas from 10 to 5 (ie. pretend in an environment where don't need to expend resources of offering 10 replicas, and can drop to 5 replicas)
        ```bash
        kubectl scale deployment.apps/openemr --replicas=5
        ```
        - It will return the following:
            ```console
            deployment.apps/openemr scaled
            ```
        - Now, there are 5 replicas of OpenEMR instead of 10. Enter the `kubectl get rs` and `kubectl get pod` to see what happened.
    - This is just a quick overview of scaling. Note we just did manual scaling in the example above, but there are also options of automatic scaling for example depending on cpu use etc.
7. Some cool replicas stuff with MariaDB. 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created by default. The number of replicas can be increased or decreased.
    - Increase replicas (after this command will have the 1 primary/master with 3 replicas/slaves).
        ```bash
        kubectl scale sts mysql-sts --replicas=4
        ```
    - Decrease replicas (after this command will have the 1 primary/master with 2 replicas/slaves).
        ```bash
        kubectl scale sts mysql-sts --replicas=3
        ```
8. Testing Redis Sentinel failover. Redis is configured with automatic failover via Sentinel. To test it:
    - First, check which Redis pod is the current master:
        ```bash
        kubectl exec redis-0 -- redis-cli --tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key --user admin -a adminpassword info replication | grep role
        ```
    - Delete the master pod to simulate a failure:
        ```bash
        kubectl delete pod redis-0
        ```
    - Watch the sentinel logs to see the failover happen (~1 second):
        ```bash
        kubectl logs sentinel-0 | grep failover
        ```
    - Verify a new master was promoted:
        ```bash
        kubectl exec redis-1 -- redis-cli --tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key --user admin -a adminpassword info replication | grep role
        ```
    - OpenEMR continues working throughout the failover — the Sentinel-based session handler automatically discovers the new master.
9. To stop and remove OpenEMR orchestration (this will delete everything):
    ```bash
    bash kub-down
    ```
    - For Kind, also need to delete the cluster:
        ````bash
        kind delete cluster
        ````

# Security Architecture

The default stance assumes components may be deployed across trust boundaries — different clusters, different VPCs, or over the public internet. Where everything is deployed in a single cluster on a hyperscaler whose infrastructure provides transparent encryption (AWS Nitro, GCP), several of these layers become defense-in-depth rather than primary protection — but they remain useful and shouldn't be removed casually. The "Connection Security" section further down documents how to relax each layer when a more limited threat model permits.

## In-transit: MariaDB connections

OpenEMR ↔ MariaDB, phpMyAdmin ↔ MariaDB, and primary ↔ replica all use mTLS by default with X509 client certificate verification, plus `MASTER_SSL_VERIFY_SERVER_CERT=1` on replica connections. All certificates are managed by cert-manager.

This provides three properties:

- **Confidentiality** of database traffic regardless of whether the underlying network is trusted.
- **Mutual authentication**: MariaDB refuses connections that don't present a valid client certificate (via `REQUIRE X509` on the GRANT statements in `mysql/configmap.yaml`). Knowing the password is not sufficient.
- **Server identity verification**: replicas refuse to follow a primary that doesn't present a cert chaining to the cluster CA, defeating man-in-the-middle replica swap attacks.

In a single-cluster deployment on AWS Nitro or GCP, the confidentiality property is redundant with hypervisor-level wire encryption, but the authentication and server-identity properties are not — they have no equivalent below the application layer.

## In-transit: Redis connections

OpenEMR ↔ Redis and OpenEMR ↔ Sentinel use mTLS via phpredis with Sentinel-based master discovery (`SESSION_STORAGE_MODE=predis-sentinel`). The `tls-auth-clients yes` setting in `redis/configmap-main.yaml` enforces client certificate presentation. Same three properties as MariaDB above.

## In-transit: NFS shared volumes

The OpenEMR pods share three RWX volumes used across pods and nodes: `websitevolume` (`/var/www/.../sites`, contains patient documents), `sslvolume` (`/etc/ssl`), and `letsencryptvolume` (`/etc/letsencrypt`). The storage layer uses **csi-driver-nfs** (standard upstream, kubernetes-sigs/csi-driver-nfs) with an in-cluster NFS backing server. NFS traffic between csi-driver-nfs on each node and the NFS server pod is wrapped in **mTLS** by two cooperating stunnel instances:

- **`nfs-server` Deployment** — nfs-ganesha serving on `127.0.0.1:2049`, with a stunnel sidecar on `0.0.0.0:20490` that terminates mTLS and forwards to the local nfs-ganesha. Backed by a `nfs-server-data` PVC (ReadWriteOnce) — all three RWX volumes consumed by openemr/phpmyadmin are subdirs of this one backing PV.
- **`nfs-stunnel-client` DaemonSet** — one pod per node running `hostNetwork: true`, listening on `127.0.0.1:12049` and forwarding mTLS to `nfs-server:20490`. The non-standard port 12049 (not 2049) avoids collision with any kernel NFS server a node might already run.
- **StorageClass `nfs`** — provisioner `nfs.csi.k8s.io`, parameters `server: 127.0.0.1, share: /nfsshare`, mountOptions `nfsvers=4.0, port=12049, noac, actimeo=0`. kubelet's NFS mount lands on each node's local stunnel-client, so all traffic between the kubelet and the NFS server is wrapped.

Both stunnels present cert-manager-issued certificates (`certs/nfs-server.yaml`, `certs/nfs-client.yaml`) rooted at the same ca-issuer the rest of the stack uses, with mutual verification on both sides: `verifyChain = yes` enforces chain-of-trust, `checkHost = nfs-client` on the server pins the acceptable peer identity to the stunnel-client's cert CN (so a compromised mysql/redis/phpmyadmin pod with its own ca-issuer-signed cert cannot bypass auth), and `checkHost = nfs-server` on the client pins the server identity symmetrically. Same three properties as MariaDB and Redis above: encrypted wire, mutual authentication, cert-manager rotation.

**Capacity caveat (shared backing PV).** csi-driver-nfs provisions each RWX PVC as a subdirectory of the single `nfs-server-data` backing PV, so the three "1Gi" per-PVC size requests are not enforced as independent quotas — all three share the backing PV's 10Gi (`nfs/nfs-server-pvc.yaml`). If `websitevolume` grows to 9 GiB, the other two have 1 GiB left between them. Monitor the backing PV's usage directly (`kubectl exec deploy/nfs-server -c nfs-server -- df -h /nfsshare`), size the backing PVC with headroom for all three, and bump `storage` on `nfs-server-pvc.yaml` ahead of expected growth. The individual PVC size fields exist only to satisfy the Kubernetes PVC API's required field.

Trade-off worth naming: NFS protocol traffic flows through two local stunnel hops per read/write op (one on the server pod, one per node), costing a few milliseconds of latency on cold reads. Caching mitigates this for hot paths. On a cloud deployment where users swap the in-cluster NFS server for a cloud-managed NFS endpoint, see **Production Hardening → Swapping to cloud-managed NFS** for the carefully-scoped encryption-in-transit discussion.

## At-rest: storage layer (not configured by default)

The default deployment backs the in-cluster NFS server with a `nfs-server-data` PVC (`nfs/nfs-server-pvc.yaml`) that claims against the cluster's default StorageClass. The MariaDB `datadir` likewise uses the default StorageClass via its `volumeClaimTemplates`. On Kind, the default StorageClass is `local-path-provisioner` — not encrypted at rest.

For dev/Kind use this is fine; relying on the workstation's full-disk encryption (LUKS / FileVault / BitLocker) is the appropriate dev posture, and Kind has no native encryption knob.

For production deployments, both PVCs can be redirected to an encrypted StorageClass with no application-code changes — see **Production Hardening → Encryption at rest (storage layer)** for per-cloud options, and **Production Hardening → MariaDB Transparent Data Encryption (TDE)** for application-layer encryption inside the database.

## Secrets management

All passwords (Redis, MariaDB replication, MariaDB root) are stored in Kubernetes Secret resources with default values suitable for development and testing. For production deployments, these Secret YAML files (`redis/secret.yaml`, `mysql/replication-secret.yaml`, `mysql/secret.yaml`, `openemr/secret.yaml`) should be replaced with secrets managed by an external secret manager (e.g., HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager) using an operator like External Secrets Operator. The rest of the deployment (init containers, env var references, volume mounts) references Kubernetes Secrets by name and requires no changes regardless of how the secrets are provisioned.

## Network policies

`network/policies.yaml` is applied at the end of `kub-up` and restricts which pods can reach which services within the cluster. Combined with mTLS and `REQUIRE X509`, this means lateral movement from a compromised pod to an unrelated database connection is gated at both the network layer and the authentication layer.

# Connection Security

The mTLS configuration above is the default. Both MariaDB and Redis connection security can be relaxed when a more limited threat model permits — for example, when running entirely within a single cluster on a hyperscaler whose infrastructure already provides wire encryption, or for development environments.

## MariaDB Connection Security
By default, MariaDB connections use **mTLS (mutual TLS)** with X509 client certificate verification for all connections (OpenEMR, phpMyAdmin, and replication). All certificates are managed by cert-manager. To downgrade the connection security:

### Downgrade to TLS (encrypted, no client certs)
1. `mysql/configmap.yaml`: In primary.sql, change `REQUIRE X509` to `REQUIRE SSL`. In secondary.sql, remove the `MASTER_SSL_CERT` and `MASTER_SSL_KEY` lines
2. `openemr/deployment.yaml`: Change `FORCE_DATABASE_X509_CONNECT` to `FORCE_DATABASE_SSL_CONNECT` and remove the `tls.crt` (mysql-cert) and `tls.key` (mysql-key) items from the `mysql-openemr-client-certs` volume
3. `phpmyadmin/configmap.yaml`: Comment out or remove the `ssl_cert` and `ssl_key` lines
4. `phpmyadmin/deployment.yaml`: Remove the `tls.crt` and `tls.key` items from the `mysql-phpmyadmin-client-certs` volume

### Downgrade to TCP (no encryption)
Perform all the TLS downgrade steps above, then additionally:
1. `mysql/configmap.yaml`: Remove `ssl_ca`, `ssl_cert`, `ssl_key` lines from both primary.cnf and replica.cnf. In primary.sql, change `REQUIRE SSL` to nothing. In secondary.sql, remove `MASTER_SSL_CA`, `MASTER_SSL`, and `MASTER_SSL_VERIFY_SERVER_CERT` lines
2. `openemr/deployment.yaml`: Remove the `FORCE_DATABASE_SSL_CONNECT` environment variable and remove the entire `mysql-openemr-client-certs` volume and volumeMount
3. `phpmyadmin/configmap.yaml`: Set `ssl` to `false`, remove `ssl_ca`, and remove `ssl_verify`
4. `phpmyadmin/deployment.yaml`: Remove the entire `mysql-phpmyadmin-client-certs` volume and volumeMount
5. `certs/mysql.yaml`, `certs/mysql-replication.yaml`, `certs/mysql-openemr-client.yaml`, `certs/mysql-phpmyadmin-client.yaml`: These cert-manager Certificate resources can be removed entirely
6. `kub-up` and `kub-down` (and `.bat` variants): Remove the mysql cert references

## Redis Connection Security
By default, Redis connections use **mTLS (mutual TLS)** with X509 client certificate verification. OpenEMR uses phpredis with Sentinel discovery for automatic failover (`SESSION_STORAGE_MODE=predis-sentinel`). All certificates are managed by cert-manager. To downgrade the connection security:

### Downgrade to TLS (encrypted, no client certs)
1. `redis/configmap-main.yaml`: Change `tls-auth-clients yes` to `tls-auth-clients no`
2. `redis/statefulset-redis.yaml`: Change `REDISX509=true` to `REDISX509=false`
3. `redis/statefulset-sentinel.yaml`: Change `REDISX509=true` to `REDISX509=false` (the sentinel config automatically sets `tls-auth-clients` based on this value)
4. `openemr/deployment.yaml`: Remove the `REDIS_X509` environment variable and remove the client cert/key items (`redis-master-cert`, `redis-master-key`, `redis-sentinel-cert`, `redis-sentinel-key`) from the `redis-openemr-client-certs` volume

### Downgrade to TCP (no encryption)
Perform all the TLS downgrade steps above, then additionally:
1. `redis/configmap-main.yaml`: Remove all `tls-*` lines, change `port 0` to `port 6379`, and remove `tls-port 6379`
2. `redis/statefulset-redis.yaml`: Remove the `TLSPARAMETERS` variable and its usage in redis-cli commands, and remove the `redis-certs` volume and volumeMount
3. `redis/statefulset-sentinel.yaml`: Remove the `TLSPARAMETERS` variable and its usage in redis-cli commands, remove the `sentinel-certs` volume and volumeMount, and remove all `tls-*` lines from the sentinel config generation
4. `openemr/deployment.yaml`: Remove the `REDIS_TLS`, `REDIS_X509`, and `REDIS_TLS_CERT_KEY_PATH` environment variables and remove the entire `redis-openemr-client-certs` volume and volumeMount
5. `certs/redis.yaml`, `certs/redis-openemr-client.yaml`, `certs/sentinel.yaml`: These cert-manager Certificate resources can be removed entirely
6. `kub-up` and `kub-down` (and `.bat` variants): Remove the redis/sentinel cert references

# Production Hardening

The stack ships with sensible defaults for development on Kind. For production deployments, the following swaps and additions are typical. None of them require changes to OpenEMR application code or to the application-level security model — they are storage and infrastructure adjustments around the existing manifests.

## Upgrading an existing cluster to the CSI-based NFS stack

This stack does not support in-place upgrades for the Kubernetes side — the storage layer and manifest wiring are redone whole-cluster. If you have an existing cluster running the older sig-storage/nfs-provisioner setup (pre-#910), the upgrade path is:

1. **Preserve any patient data on the old NFS backing** by exporting it from the running cluster (e.g. `kubectl cp` from inside an openemr pod, or snapshotting the backing storage).
2. **`bash kub-down`** on the old manifests — fully tears down the old nfs-provisioner Deployment, Service, and RBAC along with the rest of the stack, so no plaintext NFS provisioner is left behind.
3. **Pull the updated manifests** (this branch / release).
4. **`bash kub-up`** on the new manifests. The new `nfs-server` Deployment, csi-driver-nfs, stunnel pods, and mTLS certs come up from scratch.
5. **Restore patient data** into the new `websitevolume` (via `kubectl cp` back in).

Attempting to apply the new manifests on top of an old cluster without a `kub-down` first will leave the old nfs-provisioner running alongside the new csi-driver-nfs, and the StorageClass `parameters` are immutable so the old `provisioner: cluster.local/nfs-provisioner` will not be replaced by the new `nfs.csi.k8s.io` provisioner — a silent half-upgrade state.

## Encryption at rest (storage layer)

The simplest path to encryption-at-rest is to back the persistent volumes with an encrypted StorageClass at the cloud or storage-layer. Two PVCs matter:

- **MariaDB `datadir`** (RWO) — set `storageClassName` on the `volumeClaimTemplates` entry in `mysql/statefulset.yaml` to your encrypted StorageClass.
- **NFS server backing** (RWO) — set `storageClassName` on `nfs/nfs-server-pvc.yaml` to your encrypted StorageClass. The three RWX volumes (`websitevolume`, `sslvolume`, `letsencryptvolume`) consumed by openemr/phpmyadmin are provisioned as subdirs under this one backing PV by csi-driver-nfs, so they all inherit the backing disk's encryption; no changes to OpenEMR manifests are needed.

| Cloud / Environment | StorageClass | Key management |
|---|---|---|
| AWS / EKS | `gp3` with `encrypted: "true"` | AWS KMS (CMK or AWS-managed) |
| GCP / GKE | `pd-balanced` or `pd-ssd` with `disk-encryption-kms-key` | Cloud KMS / CMEK |
| Azure / AKS | `managed-csi` with `diskEncryptionSetID` | Azure Disk Encryption Set |
| On-prem (self-hosted) | Longhorn with `encrypted: "true"` | dm-crypt key in Kubernetes Secret |
| On-prem (Ceph) | Rook/Ceph with `encrypted: "true"` | dm-crypt or Vault |

Storage-layer encryption protects against stolen disks, decommissioned media, snapshot exfiltration, and backup-tape theft. It does not protect against attackers who have access to the running cluster (pods see plaintext through the mounted filesystem).

## MariaDB Transparent Data Encryption (TDE)

For defense-in-depth beyond storage-layer encryption, MariaDB's built-in `file_key_management` plugin encrypts InnoDB tablespaces, redo logs, binary logs, and temp files at the application layer. The plugin ships in the stock `mariadb:11.8.6` image used by this stack — no custom image is required.

Enabling TDE involves:

1. **A new Secret** containing the keyfile (one or more lines of `<key-id>;<32 hex chars = 16-byte AES key>`), optionally itself encrypted with a master password supplied via `file_key_management_filekey`.
2. **A volume mount** on the MariaDB container at `/etc/mysql/encryption/`, sourcing the secret with `defaultMode: 0400`.
3. **Configuration additions** to both `primary.cnf` and `replica.cnf` in `mysql/configmap.yaml`:
   ```ini
   plugin-load-add=file_key_management
   file_key_management_filename=/etc/mysql/encryption/keyfile
   file_key_management_encryption_algorithm=AES_CTR
   innodb_encrypt_tables=ON
   innodb_encrypt_log=ON
   innodb_encrypt_temporary_tables=ON
   innodb_encryption_threads=4
   encrypt-tmp-disk-tables=1
   encrypt-tmp-files=1
   encrypt-binlog=1
   aria-encrypt-tables=1
   ```

Enable TDE at first boot so the system tablespace is born encrypted. Existing tables are encrypted in the background by `innodb_encryption_threads`. Both primary and replica pods consume the same Secret and ConfigMap, so the keyfile is automatically consistent across replication.

**Trust boundary:** TDE keys live in a Kubernetes Secret, so any principal with `kubectl get secret` access in the namespace can read both the keys and the data. TDE primarily protects against PV theft, snapshot exfiltration, and decommissioned-disk recovery — not in-cluster attackers. For a stricter trust boundary, replace `file_key_management` with the HashiCorp Vault or AWS KMS key-management plugins, which require a custom MariaDB image plus pod authentication to the external KMS.

**Key rotation** with `file_key_management` is manual: append a new key ID to the keyfile, increment `innodb_encryption_rotate_key_age`, and restart. Vault/KMS plugins automate this.

**Backups:** if `mariabackup` is added to the deployment, it must have access to the same keyfile to read encrypted tablespaces.

## Swapping to cloud-managed NFS

The in-cluster `nfs-server` Deployment is a reasonable default for Kind and on-prem clusters, but production users on a hyperscaler usually prefer a managed NFS endpoint for durability and backup. Because the StorageClass is standard upstream `nfs.csi.k8s.io`, the swap is primarily a StorageClass edit — no OpenEMR manifest edits needed.

**What the in-cluster defaults look like today** (`kubernetes/nfs/storageclass.yaml`):

```yaml
parameters:
  server: 127.0.0.1
  share: /nfsshare
mountOptions:
  - nfsvers=4.0        # see ganesha config rationale in nfs-server-ganesha-configmap.yaml
  - port=12049         # loopback port of per-node stunnel-client DaemonSet
  - noac
  - actimeo=0
```

The `server`, `share`, `nfsvers`, and `port` values are all in-cluster-specific. Migration = replace them with the cloud endpoint's equivalents, and remove the in-cluster support pieces (`nfs-server-*.yaml`, `stunnel-client-*.yaml`).

| Cloud / Endpoint | `server` | `share` | `nfsvers` | `port` | Also required |
|---|---|---|---|---|---|
| AWS EFS | `fs-xxxx.efs.<region>.amazonaws.com` (EFS DNS name) | `/` | `4.1` (EFS speaks 4.1) | drop `port=12049` (EFS listens on default 2049) | Delete in-cluster NFS files + their references in `kub-up` / `kub-down`. If every node is an AWS Nitro instance in the same VPC as the EFS mount target, hyperscaler encryption-in-transit applies; otherwise see the encryption section below. |
| GCP Filestore | Filestore instance IP | Filestore file-share name (e.g. `/vol1`) | `4.1` (Filestore Basic is 3, Enterprise/Zonal is 4.1 — pick the tier with 4.1) | drop `port=12049` | Same deletions as EFS. See encryption notes below. |
| Azure Files (NFS 4.1) | storage-account FQDN (e.g. `myacct.file.core.windows.net`) | share path (e.g. `/myacct/share1`) | `4.1` (Azure Files NFS only speaks 4.1) | drop `port=12049` | Same deletions as EFS. See encryption notes below. |
| On-prem managed NFS | NFS appliance IP or DNS name | the appliance's export path | match the appliance's supported minor version | drop `port=12049` unless the appliance listens on it | Same deletions as EFS. The stunnel-client DaemonSet becomes dead code once `server` is anything other than `127.0.0.1` — the DaemonSet listens only on the node loopback, and csi-driver-nfs's mount now dials the external appliance directly. Plan a separate encrypted transport (e.g. IPsec tunnel between the Kubernetes nodes and the NFS appliance, or NFSv4-with-Kerberos). |

**Important: StorageClass `parameters` and `mountOptions` are immutable.** Kubernetes rejects edits to either field on an existing StorageClass, and existing PVs retain whatever values they were originally provisioned with. The clean migration path is `kub-down` → wait for cluster-level teardown → edit `storageclass.yaml` → `kub-up`. For a cluster that has live patient data on the in-cluster NFS backing, migrate the data to the new endpoint first (e.g. snapshot the backing PVC, restore into the managed NFS filesystem) *before* running `kub-down`.

**Encryption-in-transit on the cloud path.** The default `nfs` StorageClass uses the kernel NFS client — it does not auto-negotiate TLS to the server. The in-cluster stunnel-client DaemonSet only wraps traffic because `parameters.server` points at `127.0.0.1`, which routes through the local DaemonSet pod. Once `parameters.server` is changed to any external endpoint, csi-driver-nfs's kubelet mount dials the external address directly and the DaemonSet becomes unused — the mount is plaintext regardless of whether the DaemonSet exists. The cloud path's encryption therefore depends entirely on the mount endpoint, not on anything we deploy inside the cluster. By cloud:

- **AWS EFS**: encryption-in-transit requires mounting via `efs-utils` with the `tls` option (which spawns a local `stunnel`-equivalent on each node) OR mounting over a path that goes through AWS Nitro's hypervisor-level NIC encryption (same-VPC Nitro-to-Nitro only). csi-driver-nfs does **not** use `efs-utils`, so you must either ensure every node is a Nitro instance in the same VPC as the EFS mount target, or front csi-driver-nfs with an `efs-utils`-compatible layer.
- **GCP Filestore**: TLS is available only on specific tiers (Enterprise, Zonal with HSM) and only when mounting with GCP's `fscrypt`/`gcsfuse` wrappers — not via plain `nfs.csi.k8s.io`.
- **Azure Files NFS**: Private Endpoint traffic bypasses VNet-level encryption; use SMB with Kerberos for in-transit encryption instead of NFS, or plan a separate encrypted transport (IPsec, WireGuard between nodes and endpoint).
- **On-prem managed NFS**: no cloud-level encryption applies and the stunnel-client DaemonSet does not wrap this path. Plan a separate encrypted transport (IPsec tunnel to the appliance, or NFSv4-with-Kerberos).

Short version: when `parameters.server` is `127.0.0.1` (default), the stunnel-client DaemonSet wraps everything. When it's any external endpoint, cloud-level or appliance-level encryption is the only encryption you have — confirm it covers your specific tier/instance combo end-to-end.

**Encryption-at-rest on the cloud path:** all three managed endpoints encrypt at rest by default with cloud-provider keys. For CMEK/CMK, see the respective cloud's documentation.

## CNI-level pod-to-pod encryption

In addition to the application-level and NFS-level mTLS this stack already uses, some deployments want blanket pod-to-pod encryption below the application layer. This wraps all node-to-node pod traffic regardless of workload, which is useful for defense-in-depth and for any supplementary traffic that doesn't go through the stack's mTLS layers.

| Environment | Approach |
|---|---|
| AWS / EKS on Nitro instances | Hyperscaler-native: same-VPC traffic between Nitro hypervisors is encrypted at the NIC level by AWS, transparent to pods. Typically sufficient for HIPAA encryption-in-transit attestation. |
| GCP / GKE | Same property — Google encrypts VM-to-VM traffic within a VPC at their network fabric layer. |
| Azure / AKS | More variable depending on VM SKU and region; check the specific SKU. Add CNI WireGuard if uncertain. |
| Any cluster (portable) | Cilium with `encryption.enabled=true, encryption.type=wireguard`, or Calico with WireGuard mode. Single config flag, encrypts all pod-to-pod traffic. |
| On-prem / air-gapped | CNI WireGuard (Cilium or Calico) is the standard. |

Service meshes (Istio, Linkerd) provide mTLS for application traffic but do not cover storage paths because those mounts happen at the kubelet, not in the pod — which is why this stack handles NFS encryption at the stunnel layer rather than relying on a mesh.

## Production checklist

When adapting this stack for a production deployment, the typical hardening checklist is:

- [ ] Replace default passwords in all `*-credentials` and `*-secret.yaml` files (or wire up External Secrets Operator).
- [ ] Set `storageClassName` on `mysql/statefulset.yaml` `volumeClaimTemplates` to an encrypted StorageClass.
- [ ] Set `storageClassName` on `nfs/nfs-server-pvc.yaml` to an encrypted StorageClass — OR swap the in-cluster NFS server for a cloud-managed endpoint (EFS/Filestore/Azure Files) via **Swapping to cloud-managed NFS** above.
- [ ] Decide on TDE: enable at first boot if defense-in-depth is desired; document the key rotation runbook.
- [ ] Confirm pod-to-pod encryption: rely on hyperscaler-native (AWS Nitro / GCP), enable CNI WireGuard, or confirm the application-level + NFS-level mTLS layers already cover your threat model.
- [ ] Review `network/policies.yaml` for your namespace topology.
- [ ] Replace the self-signed cert-manager CA with a CA chained to your organization's PKI if cross-cluster trust is required.
- [ ] Determine ingress: the default NodePort exposure is for development; production typically fronts OpenEMR with an Ingress Controller and an external load balancer with proper TLS termination.
