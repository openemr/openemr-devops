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
1. Install Kind. Other Kubernetes distributions can be substituted by users familiar with their networking and storage models, but the instructions below assume Kind.
    - For Kind, see below for instructions sets with 1 node or 4 nodes.
        - 1 node:
            ```bash
            kind create cluster --config kind-config-1-node.yaml
            ```
        - 4 nodes (1 control-plane node and 3 worker nodes). Shared volumes use an in-cluster NFS provisioner (deployed by kub-up) so pods on different nodes can share ReadWriteMany volumes:
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
          pod/nfs-provisioner-77f85859c4-xxxxx   1/1     Running   0          3m
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

          NAME                      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                        AGE
          service/kubernetes        ClusterIP   10.96.0.1      <none>        443/TCP                        3m40s
          service/mysql             ClusterIP   None           <none>        3306/TCP                       111s
          service/nfs-provisioner   ClusterIP   10.96.1.73     <none>        2049/TCP,2049/UDP,...           3m
          service/openemr           NodePort    10.96.6.51     <none>        8080:30080/TCP,8090:30443/TCP   111s
          service/phpmyadmin        ClusterIP   10.96.64.163   <none>        8081/TCP,8091/TCP              111s
          service/redis             ClusterIP   None           <none>        6379/TCP                       111s
          service/sentinel          ClusterIP   None           <none>        26379/TCP                      111s

          NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
          deployment.apps/nfs-provisioner   1/1     1            1           3m
          deployment.apps/openemr           3/3     3            3           111s
          deployment.apps/phpmyadmin        1/1     1            1           111s

          NAME                                         DESIRED   CURRENT   READY   AGE
          replicaset.apps/nfs-provisioner-77f85859c4   1         1         1       3m
          replicaset.apps/openemr-7889cf48d8           3         3         3       111s
          replicaset.apps/phpmyadmin-f4d9bfc69         1         1         1       111s

          NAME                         READY   AGE
          statefulset.apps/mysql-sts   2/2     111s
          statefulset.apps/redis       3/3     111s
          statefulset.apps/sentinel    3/3     111s
          ```
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
            NAME                         DESIRED   CURRENT   READY   AGE
            nfs-provisioner-77f85859c4   1         1         1       11m
            openemr-7889cf48d8           3         3         3       9m22s
            phpmyadmin-f4d9bfc69         1         1         1       9m22s
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

## In-transit: NFS shared volumes (gap)

The OpenEMR pods share three RWX volumes via the in-cluster NFS provisioner: `websitevolume` (`/var/www/.../sites`, contains patient documents), `sslvolume` (`/etc/ssl`), and `letsencryptvolume` (`/etc/letsencrypt`). NFS traffic between OpenEMR pods and the NFS provisioner pod is **not** encrypted by default — it uses NFSv4.1 over plain TCP with `sec=sys`.

mTLS sidecars and service meshes do not cover this path. NFS mounts are performed by the kubelet on the host network namespace, not by the pod, so application-layer mesh sidecars never see the traffic.

For deployments where this matters, see **Production Hardening → CNI-level pod-to-pod encryption** below for the standard fix.

## At-rest: storage layer (not configured by default)

The default deployment uses an in-cluster NFS provisioner (`nfs/deployment.yaml`) backed by a `hostPath: /tmp/nfs-provisioner`, and the MariaDB `datadir` uses the cluster's default StorageClass. Neither is encrypted at rest by default.

For dev/Kind use, this is fine — relying on the workstation's full-disk encryption (LUKS / FileVault / BitLocker) is the appropriate dev posture, and Kind has no native encryption knob.

For production deployments, see **Production Hardening → Encryption at rest (storage layer)** for storage-layer encryption options per cloud, and **Production Hardening → MariaDB Transparent Data Encryption (TDE)** for application-layer encryption inside the database.

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

## Encryption at rest (storage layer)

The simplest path to encryption-at-rest is to back the persistent volumes with an encrypted StorageClass at the cloud or storage-layer. Two PVCs matter:

- **MariaDB `datadir`** (RWO) — set `storageClassName` on the `volumeClaimTemplates` entry in `mysql/statefulset.yaml` to your encrypted StorageClass.
- **NFS provisioner backing** — replace the `hostPath: /tmp/nfs-provisioner` in `nfs/deployment.yaml` with a PVC backed by your encrypted StorageClass. The three RWX volumes (`websitevolume`, `sslvolume`, `letsencryptvolume`) inherit encryption from this single backing disk; no changes to OpenEMR manifests are needed.

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

## CNI-level pod-to-pod encryption

For the NFS shared-volume in-transit gap (and for any other pod-to-pod traffic outside the application-mTLS layers), the standard answer is CNI-level transparent encryption. This wraps all node-to-node pod traffic regardless of workload, including NFS, iSCSI, and the kubelet-initiated paths that service meshes can't reach.

| Environment | Approach |
|---|---|
| AWS / EKS on Nitro instances | Hyperscaler-native: same-VPC traffic between Nitro hypervisors is encrypted at the NIC level by AWS, transparent to pods. Typically sufficient for HIPAA encryption-in-transit attestation. |
| GCP / GKE | Same property — Google encrypts VM-to-VM traffic within a VPC at their network fabric layer. |
| Azure / AKS | More variable depending on VM SKU and region; check the specific SKU. Add CNI WireGuard if uncertain. |
| Any cluster (portable) | Cilium with `encryption.enabled=true, encryption.type=wireguard`, or Calico with WireGuard mode. Single config flag, encrypts all pod-to-pod traffic. |
| On-prem / air-gapped | CNI WireGuard (Cilium or Calico) is the standard. |

Service meshes (Istio, Linkerd) provide mTLS for application traffic but do not cover NFS or storage paths because those mounts happen at the kubelet, not in the pod. For the NFS gap specifically, CNI-level encryption is the right tool.

## Production checklist

When adapting this stack for a production deployment, the typical hardening checklist is:

- [ ] Replace default passwords in all `*-credentials` and `*-secret.yaml` files (or wire up External Secrets Operator).
- [ ] Set `storageClassName` on `mysql/statefulset.yaml` `volumeClaimTemplates` to an encrypted StorageClass.
- [ ] Replace the NFS provisioner's `hostPath` with a PVC on an encrypted StorageClass.
- [ ] Decide on TDE: enable at first boot if defense-in-depth is desired; document the key rotation runbook.
- [ ] Confirm pod-to-pod encryption: rely on hyperscaler-native (AWS Nitro / GCP) or enable CNI WireGuard.
- [ ] Review `network/policies.yaml` for your namespace topology.
- [ ] Replace the self-signed cert-manager CA with a CA chained to your organization's PKI if cross-cluster trust is required.
- [ ] Determine ingress: the default NodePort exposure is for development; production typically fronts OpenEMR with an Ingress Controller and an external load balancer with proper TLS termination.
