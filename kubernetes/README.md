# Overview

This Kubernetes deployment serves two related goals:

1. **A working starting point.** A complete, runnable OpenEMR environment on Kubernetes — usable on Kind for local development and adaptable for production deployments on EKS, GKE, AKS, or on-prem clusters.
2. **A reference for secure distributed deployments.** The stack demonstrates the security primitives (mTLS with X509 client certificate verification, encrypted MariaDB replication, Redis Sentinel with mTLS) needed when OpenEMR components may be installed across trust boundaries — different clusters, different VPCs, or communicating over the public internet.

Which lens you read this through affects what's essential vs. defense-in-depth:

- **Single-cluster production users** (one EKS/GKE/AKS cluster on modern hyperscaler hardware): the cloud provider's transparent infrastructure encryption already covers wire confidentiality between nodes. The mTLS layers in this stack are then defense-in-depth and provide endpoint authentication; see "Security Architecture" for what each layer adds and "Connection Security" for downgrade paths.
- **Distributed deployment users** (components separated across networks or trust boundaries): the mTLS layers are load-bearing — they're the only thing protecting and authenticating connections that cross untrusted networks. Don't disable them.

> **Requires OpenEMR 8.6.0 (not yet released) — currently pinned to the 8.6.0 dev image.** Every stable OpenEMR release up through 8.5.0 carries a Kubernetes-specific first-boot race ([openemr#15084](https://github.com/openemr/openemr/pull/15084)) where `Installer::quick_install()` wrote `sqlconf.php` with `$config = 1` BEFORE `install_gacl()` / `install_additional_users()` / `on_care_coordination()` committed. A Kubelet-restarted pod observing that intermediate state treats the install as complete and never re-seeds, leaving a half-seeded DB — login succeeds but patient operations return permission-denied. The fix merged to master for 8.6.0; this stack therefore pins `openemr/openemr:8.6.0` (the daily-rebuilt dev image tracking master) via the floating `8.6.0` tag with a SHA pin that Dependabot auto-bumps. Once 8.6.0 ships as a formal release, the same `8.6.0` tag will point at the production image and Dependabot flips the SHA automatically — no manifest edit required. Until that release lands, **this stack does NOT work with any stable OpenEMR production version** (8.5.0 or earlier). The flex Docker series is also supported for development purposes (change to `openemr/openemr:flex` in `openemr/deployment.yaml`, though startup will be significantly slower as each instance builds from source). While not a fully hardened production deployment, this provides a solid working foundation with mTLS encryption, Redis Sentinel failover, and multi-node support, and should open the door to a myriad of other Kubernetes-based solutions.

OpenEMR Kubernetes orchestration. Orchestration includes OpenEMR, MariaDB, Redis, and phpMyAdmin.
  - **OpenEMR** - 3 deployment replications of OpenEMR are created. Replications can be increased/decreased. Ports for both http and https.
  - **MariaDB** - a 2-replica MariaDB cluster (1 primary with 1 replica) managed declaratively by the [MariaDB Operator](https://github.com/mariadb-operator/mariadb-operator). The operator owns the StatefulSet, Services (`mysql-primary` for writes, `mysql-secondary` for reads, `mysql` for all), replication (semi-synchronous with `waitPoint: AfterSync` for durability), automatic primary failover, and TLS (operator issues its own server cert via the shared `ca-issuer`). Connections use mTLS (mutual TLS / X509 client certificate verification) by default, including replication traffic. The operator orchestrates failover (promote replica → fence demoted primary → switch Service endpoints) so cert rotation and primary pod cutover produce only a sub-second reconnect window from the client's perspective — no committed transactions are lost. See **Security Architecture → MariaDB connections** for what mTLS protects, **Certificate reload mechanism** for the full rotation story, and **Connection Security → MariaDB Connection Security** for how to downgrade to TLS-only or plain TCP.
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
          NAME                                                READY   STATUS    RESTARTS   AGE
          pod/mariadb-operator-xxxxxxxxxx-xxxxx                   1/1     Running   0          2m
          pod/mariadb-operator-cert-controller-xxxxxxxxx-xxxxx    1/1     Running   0          2m
          pod/mariadb-operator-webhook-xxxxxxxxx-xxxxx            1/1     Running   0          2m
          pod/mysql-0                                             2/2     Running   0          111s
          pod/mysql-1                                             2/2     Running   0          91s
          pod/nfs-server-74f8d9c7b5-xxxxx                         2/2     Running   0          3m
          pod/nfs-stunnel-client-abcde                            1/1     Running   0          3m
          pod/openemr-7889cf48d8-9jdfl                            1/1     Running   0          111s
          pod/openemr-7889cf48d8-qphrw                            1/1     Running   0          111s
          pod/openemr-7889cf48d8-zlx9f                            1/1     Running   0          111s
          pod/phpmyadmin-f4d9bfc69-rx82d                          1/1     Running   0          111s
          pod/redis-0                                             1/1     Running   0          111s
          pod/redis-1                                             1/1     Running   0          77s
          pod/redis-2                                             1/1     Running   0          55s
          pod/reloader-reloader-xxxxxxxxx-xxxxx                   1/1     Running   0          2m
          pod/sentinel-0                                          1/1     Running   0          111s
          pod/sentinel-1                                          1/1     Running   0          34s
          pod/sentinel-2                                          1/1     Running   0          30s

          NAME                       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                        AGE
          service/kubernetes         ClusterIP   10.96.0.1      <none>        443/TCP                        3m40s
          service/mysql              ClusterIP   None           <none>        3306/TCP                       111s
          service/mysql-primary      ClusterIP   10.96.5.10     <none>        3306/TCP                       111s
          service/mysql-secondary    ClusterIP   10.96.5.11     <none>        3306/TCP                       111s
          service/nfs-server         ClusterIP   10.96.1.73     <none>        20490/TCP                      3m
          service/openemr            NodePort    10.96.6.51     <none>        8080:30080/TCP,8090:30443/TCP   111s
          service/phpmyadmin         ClusterIP   10.96.64.163   <none>        8081/TCP,8091/TCP              111s
          service/redis              ClusterIP   None           <none>        6379/TCP                       111s
          service/sentinel           ClusterIP   None           <none>        26379/TCP                      111s

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
          statefulset.apps/mysql       2/2     111s
          statefulset.apps/redis       3/3     111s
          statefulset.apps/sentinel    3/3     111s

          NAME                      READY   STATUS    PRIMARY   AGE
          mariadb.k8s.mariadb.com/mysql   True    Running   mysql-0   111s
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
7. Some cool replicas stuff with MariaDB. 2 statefulset replications of MariaDB (1 primary with 1 replica) are created by default by the MariaDB Operator. Change the replica count by editing the `MariaDB` resource (NOT the generated StatefulSet directly — the operator will reconcile that back):
    - **Decreasing** replicas works out of the box: the operator removes the extra replica pod cleanly. **Leftover PVC caveat**: the pod's PVC (`storage-mysql-N`) is NOT deleted by the operator on scale-down — StatefulSet-style PVCs persist across scale-down so a subsequent scale-up on the same ordinal would reuse the same data. If you scale back up later, the retired replica's stale PVC will be reused (good for same-cluster fast-reattach; bad if the stale data is far enough behind that the operator rejects it as un-catchable). Check and remove it explicitly if needed before scaling back up:
        ```bash
        # 3 -> 2 replicas total (1 primary + 1 replica)
        kubectl patch mariadb mysql --type=merge -p '{"spec":{"replicas":2}}'
        # Later, before scaling back from 2 -> 3, inspect what PVCs exist.
        # Operator-created PVCs carry its canonical selectors, not the
        # app=mysql label we inject onto pods — name-match is the reliable
        # way to find them:
        kubectl get pvc | grep '^storage-mysql-'
        # If a stale PVC from the retired ordinal is present and you want
        # a fresh bootstrap (not reattach to stale data), delete it:
        #   kubectl delete pvc storage-mysql-2
        # Then proceed with the scale-up below.
        ```
    - **Increasing** replicas requires a bootstrap path first — the new replica needs a seed to hydrate from (otherwise mysqld starts empty and can't catch up on a running cluster). The MariaDB Operator exposes this via a separate `PhysicalBackup` CRD referenced from the `MariaDB` resource:
       1. Create a `PhysicalBackup` resource (its own kind, not a field on `MariaDB`) — see the [operator's PhysicalBackup docs](https://github.com/mariadb-operator/mariadb-operator/blob/main/docs/physical_backup.md) for schema and storage-target options.
       2. Edit the `MariaDB` resource to add `spec.replication.replica.bootstrapFrom.physicalBackupTemplateRef: { name: <your-physicalbackup-name> }` so new replicas know where to hydrate from.
       3. Patch replicas up:
          ```bash
          kubectl patch mariadb mysql --type=merge -p '{"spec":{"replicas":3}}'
          ```
      The default 2-replica topology (1 primary + 1 replica, bootstrapped at cluster-create time from the empty primary) works without any backup configuration — this scale-out step is only needed when going beyond that.
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

OpenEMR ↔ MariaDB, phpMyAdmin ↔ MariaDB, and primary ↔ replica all use mTLS by default with X509 client certificate verification. All certificates are managed by cert-manager.

This provides three properties:

- **Confidentiality** of database traffic regardless of whether the underlying network is trusted.
- **Mutual authentication**: client-cert enforcement is applied PER ACCOUNT, not listener-wide. `spec.tls.enabled: true` on the `MariaDB` resource (`kubernetes/mysql/mariadb.yaml`) enables TLS — the server advertises TLS support and clients CAN connect with a cert — but the server does not globally require clients to present a cert for every connection. What makes client-cert verification load-bearing for openemr specifically is the account-level grant: openemr's own first-boot creates the openemr user with `REQUIRE X509` (via `FORCE_DATABASE_X509_CONNECT=1` in `openemr/deployment.yaml`), so even an attacker with the openemr password cannot authenticate as that user without presenting a trusted client cert. The MariaDB Operator manages primary ↔ replica replication TLS internally with `clientCertIssuerRef`-provisioned certs, and configures replication with server-cert verification so a MITM primary is rejected on that specific path. Other accounts (root, operator-created helpers) do NOT carry `REQUIRE X509` — operators who need listener-wide X509 enforcement must add `spec.tls.required: true` AND grant `REQUIRE X509` on each account that must comply.
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

**Capacity caveat (shared backing PV).** csi-driver-nfs provisions each RWX PVC as a subdirectory of the single `nfs-server-data` backing PV, so the three "1Gi" per-PVC size requests are not enforced as independent quotas — all three share the backing PV's 10Gi (`nfs/nfs-server-pvc.yaml`). If `websitevolume` grows to 9 GiB, the other two have 1 GiB left between them. Monitor the backing PV's usage directly (`kubectl exec deploy/nfs-server -c nfs-server -- df -h /nfsshare`), size the backing PVC with headroom for all three, and bump `storage` on `nfs-server-pvc.yaml` ahead of expected growth. The individual PVC size fields exist only to satisfy the Kubernetes PVC API's required field. (On Kind specifically, the default `local-path-provisioner` does not enforce the backing PVC's size request either, so the 10 GiB is a planning budget rather than a hard cap — the whole node filesystem is accessible to the pod. In a cloud with a quota-enforcing StorageClass behind the backing PVC, the request *is* a hard cap and sizing it correctly matters.)

Trade-off worth naming: NFS protocol traffic flows through two local stunnel hops per read/write op (one on the server pod, one per node), costing a few milliseconds of latency on cold reads. Caching mitigates this for hot paths. On a cloud deployment where users swap the in-cluster NFS server for a cloud-managed NFS endpoint, see **Production Hardening → Swapping to cloud-managed NFS** for the carefully-scoped encryption-in-transit discussion.

## At-rest: storage layer (not configured by default)

The default deployment backs the in-cluster NFS server with a `nfs-server-data` PVC (`nfs/nfs-server-pvc.yaml`) that claims against the cluster's default StorageClass. The MariaDB `datadir` likewise uses the default StorageClass via its `volumeClaimTemplates`. On Kind, the default StorageClass is `local-path-provisioner` — not encrypted at rest.

For dev/Kind use this is fine; relying on the workstation's full-disk encryption (LUKS / FileVault / BitLocker) is the appropriate dev posture, and Kind has no native encryption knob.

For production deployments, both PVCs can be redirected to an encrypted StorageClass with no application-code changes — see **Production Hardening → Encryption at rest (storage layer)** for per-cloud options, and **Production Hardening → MariaDB Transparent Data Encryption (TDE)** for application-layer encryption inside the database.

## Secrets management

All passwords (Redis, MariaDB replication, MariaDB root) are stored in Kubernetes Secret resources with default values suitable for development and testing. For production deployments, these Secret YAML files (`redis/secret.yaml`, `mysql/replication-secret.yaml`, `mysql/secret.yaml`, `openemr/secret.yaml`) should be replaced with secrets managed by an external secret manager (e.g., HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager) using an operator like External Secrets Operator. The rest of the deployment (init containers, env var references, volume mounts) references Kubernetes Secrets by name and requires no changes regardless of how the secrets are provisioned.

## Network policies

`network/policies.yaml` is applied at the end of `kub-up` and restricts which pods can reach which services within the cluster. Combined with mTLS and `REQUIRE X509`, this means lateral movement from a compromised pod to an unrelated database connection is gated at both the network layer and the authentication layer.

## Certificate reload mechanism

**Explicitly-configured leaf certificates** in `kubernetes/certs/*.yaml` (the per-consumer client certs and server certs for Redis, Sentinel, NFS, phpMyAdmin) use `duration: 168h` (7 days) and `renewBefore: 48h` (2 days), producing a rotation cadence of roughly **every 5 days** per certificate (duration − renewBefore). cert-manager handles the lifecycle: 48h before expiry it re-issues the cert under the same `ca-issuer` and UPDATEs the referenced Secret's `tls.crt` / `tls.key` payload in place.

**Operator-managed certificates** (the MariaDB server cert + replication-client cert, issued via `tls.serverCertIssuerRef` / `tls.clientCertIssuerRef` in `kubernetes/mysql/mariadb.yaml`) use the MariaDB Operator's own default lifetime, NOT the 168h / 48h shape above. Operator 26.10.2's TLS CRD surface doesn't expose a duration override, so the MariaDB server cert rotates on the operator's schedule rather than every 5 days. The rotation PATH is still identical (and fully validated by CI): the operator's cert-controller sees Secret UPDATE → rolls the StatefulSet with failover orchestration.

Cert-manager's rotation updates the Secret but does **not** reload the running pods — mysqld, redis-server, stunnel, and the apache/openemr PHP process all parse their cert files once at startup and keep using the parsed values until the process restarts. Bridging that gap takes two separate mechanisms depending on the workload:

- **MariaDB cluster**: the [MariaDB Operator](https://github.com/mariadb-operator/mariadb-operator) (installed by `kub-up` from `mariadb-operator-26.10.2/manifests.min.yaml`, same 5-attempt linear-backoff retry as cert-manager) owns the full cluster lifecycle — StatefulSet, Services, replication, TLS, and crucially the **cert-triggered rolling restart with primary-failover orchestration**. When the server Certificate rotates, the operator's cert-controller sees the Secret UPDATE and rolls pods with: promote replica → fence the demoted primary → switch the `mysql-primary` Service endpoints → bring the replaced pod back as the new replica. Semi-sync `AfterSync` on the MariaDB resource (`kubernetes/mysql/mariadb.yaml`) means transactions committed on the old primary are durable at the replica before the switchover, so there is no in-flight-transaction loss window.
- **Everything else**: [stakater/reloader](https://github.com/stakater/Reloader) (installed by `kub-up` from `v1.4.23`, same retry shape) watches the Secrets each cert-consuming workload names in a `secret.reloader.stakater.com/reload` annotation and issues `kubectl rollout restart` on UPDATE.

Per-workload reload path:

| Workload | Reload mechanism | Secret(s) watched |
|---|---|---|
| `mysql` MariaDB cluster | **MariaDB Operator cert-controller** (not reloader) | operator-managed (`mysql-server-cert`) |
| `redis` StatefulSet | stakater/reloader | `redis-certs` |
| `sentinel` StatefulSet | stakater/reloader | `sentinel-certs` |
| `openemr` Deployment (default + both encryption-at-rest examples) | stakater/reloader | `mysql-openemr-client-certs`, `redis-openemr-client-certs` |
| `phpmyadmin` Deployment | stakater/reloader | `phpmyadmin-server-certs`, `mysql-phpmyadmin-client-certs` |
| `nfs-server` Deployment | stakater/reloader | `nfs-server-certs` |
| `nfs-stunnel-client` DaemonSet | stakater/reloader | `nfs-client-certs` |

### Data-plane impact during rotation, by workload

- **MariaDB cluster**. The operator orchestrates failover: the `mysql-primary` Service endpoints track the current primary pod, and endpoint propagation to kube-proxy is bounded by the operator's promotion-before-termination sequence. **Read availability** survives rotation with a sub-second reconnect window from the client's perspective — this is what the CI rotation test validates, via a 1 Hz `SELECT 1` mTLS probe from openemr through `mysql-primary` across the rotation window, asserting **zero FAIL iterations** (`.github/workflows/test-kubernetes.yml` — "Verify cert rotation triggers workload reload and preserves data plane"). **Write availability** during switchover is narrower: the operator locks the old primary against new writes before promoting the replica, so there is a brief write-unavailability window (typically seconds). **Durability** of committed writes depends on semi-sync `AfterSync` with `semiSyncAckTimeout: 10s` — within that budget, committed transactions are durable on the replica before failover. If the ACK timeout is reached before the replica responds, mariadb falls back to asynchronous replication for subsequent commits; writes committed during that fallback window can be lost if the primary fails before replication catches up.
- **redis + sentinel** StatefulSets. Sentinel's `down-after-milliseconds: 5000` means a failing primary takes up to 5 s to be marked down before Sentinel re-elects, plus the failover-and-reconnect window itself. **Session durability on primary rotation** is handled via Redis synchronous replication: this stack sets `REDIS_SESSION_WAIT_REPLICAS=2` on the openemr Deployment (requires openemr 8.6.0+, shipped in [openemr#15220](https://github.com/openemr/openemr/pull/15220)), so every session write blocks until BOTH replicas have ACKed before the request returns. On a 1-primary + 2-replica cluster, whichever replica Sentinel elects to promote on failover is guaranteed to have the write, so the session survives. **Why 2, not 1**: with `waitReplicas=1`, Sentinel can still elect the one replica that didn't ACK the write, roughly halving the actual failover-durability guarantee — matching the knob to the replica count closes that gap at the cost of a few extra milliseconds per write (max replica RTT vs min) and more log noise during routine replica maintenance (shortfall warnings while one pod is restarting). Operators who prefer lower noise over the full guarantee can drop to `"1"` in the manifest. **Caveats**: (a) shortfall mode — if fewer replicas than requested ACK within the WAIT timeout (default 1000 ms, clamped at 2500 ms by SentinelUtil below the 3 s Redis socket read timeout), the write still succeeds and a warning is logged; operators who need strict durability should alert on those log entries and tune `REDIS_SESSION_WAIT_TIMEOUT_MS` with awareness of the ceiling. (b) WAIT's guarantee is "replica received the write", not "replica applied it"; both are sufficient for failover durability in this stack because the promoted replica catches up its replication buffer before serving writes. (c) phpredis's native session handler (`session.save_handler = redis` in php.ini) bypasses `LockingRedisSessionHandler` / WAIT entirely and is not an HA-safe path — openemr-devops requires `SESSION_STORAGE_MODE=predis-sentinel`, which is what the Deployment manifest sets.
- **nfs-server** Deployment (single replica, Recreate). The csi-driver-nfs mounts on each node reconnect automatically through the stunnel-client DaemonSet. Pod I/O waiting on an NFS read during the cutover blocks for ~5-10s then resumes.
- **nfs-stunnel-client** DaemonSet. One pod per node; rolling restart replaces them one node at a time by default. During a node's stunnel-client cutover, that node's openemr pods see the same ~5-10s NFS blip as above.
- **phpmyadmin** Deployment (single replica). Admin-only tool; cert rotation causes a few seconds of 503 for users currently in the UI.
- **openemr** default Deployment (`openemr/deployment.yaml`). Uses `strategy: RollingUpdate` (`maxSurge: 1, maxUnavailable: 0`), so cert rotation rolls pods one at a time with at least `replicas-1` Ready throughout — no user-visible outage. openemr's own SWARM_MODE leader-election handles concurrent-boot safely (exercised continuously by the gocryptfs example which has shipped the same strategy since day one).
- **openemr LUKS example** (`kubernetes/examples/encryption-at-rest-luks/openemr-deployment-luks.yaml`). **Must stay `strategy: Recreate`** — the LUKS container file is a single-writer resource (one pod holds the dm-crypt mapping at a time) and a rolling update would attempt to open the mapping from a second pod before the first released it, causing an opaque mount failure. *Caveat on single-writer safety:* `strategy: Recreate` is a scheduling-time hint, not a guarantee — it prevents the scheduler from creating a new pod until the previous one reports terminated, but it does NOT fence a pod that has been partitioned off the network, hung mid-SIGTERM, or force-deleted with `--grace-period=0 --force`. In those edge cases the old pod can still hold the dm-crypt mapping while k8s schedules a new pod that attempts to open it. Operators who need stronger-than-Recreate single-writer semantics should pair this with a storage-level lease the sidecar acquires before `cryptsetup luksOpen`. Cert rotation outage here is a brief single-pod blip; operators who want zero-downtime openemr cert rotation should prefer the default or gocryptfs examples.
- **openemr gocryptfs example** (`kubernetes/examples/encryption-at-rest-gocryptfs/openemr-deployment-gocryptfs.yaml`). `strategy: RollingUpdate` (gocryptfs's `-sharedstorage` mode supports concurrent mounts). Cert rotation produces no user-visible openemr outage.

### MariaDB HA architecture details

The MariaDB Operator approach implements the three-part HA contract that makes zero-downtime rotation possible on an SQL backend:

1. **Automatic promotion**: when the primary pod rolls, the operator promotes the replica to primary (sets `read_only=OFF` on the new primary, runs `CHANGE MASTER TO` on the old one when it comes back) before terminating the old pod.
2. **Fencing** differs between controlled switchover and failover:
   - **Controlled switchover** (planned — cert rotation, operator-initiated roll, maintenance): the operator sets `FLUSH TABLES WITH READ LOCK` + `SET GLOBAL read_only = ON` on the old primary BEFORE promoting the replica. This refuses new transactions at the mysqld layer even if a client is still connected to the old pod. The operator then switches the `mysql-primary` Service endpoint. Switching the endpoint alone would NOT be fencing (existing TCP connections persist across endpoint changes, the pod's listener stays up until terminated); the read-only lock is what gates writes during the handoff. **Caveats worth knowing**:
     - The `read_only` lock is RELEASED when the old primary is reconfigured as a replica (that's the point — a replica needs to be able to apply replication writes). Any divergent write that lands between release and the replica rejoining the replication stream would corrupt replication. The operator sequences this carefully, but operators adding custom workflows on top should be aware.
     - MariaDB's `READ_ONLY ADMIN` privilege bypasses `read_only`. Accounts with that privilege (which includes `SUPER` on older MariaDB) can still write when the server is in read-only mode. The stack's grants don't give `openemr` or `phpmyadmin` this privilege, but operator-created helpers or admin maintenance accounts might — restrict privileged writers during the switchover window.
     - Write-privilege revocation is NOT part of the switchover sequence. `read_only` is the only enforced gate; GRANTs are unchanged across the switchover.
     This is the path cert rotation exercises.
   - **Failover** (unplanned — primary pod crashes or becomes unreachable): the operator CANNOT reach the old primary to set `read_only = ON`, so it cannot fence that way. It still promotes an eligible replica to minimize downtime, but if the old primary is network-partitioned-but-live (not actually dead), it can continue accepting writes from any clients that still have a working connection to it, until something else (pod eviction, TCP keepalive timeout, kubelet restart) breaks those connections. **Split-brain is not impossible in the failover path** — it's bounded by how long the stale connections survive, not by operator action. Production operators who require strict split-brain prevention should layer node-level fencing (STONITH-style) or switch to Galera (synchronous multi-master — every write requires quorum, no single primary to partition).
3. **Durability**: semi-synchronous replication with `waitPoint: AfterSync` means the primary blocks commit until the replica has ACKed the binlog write, so transactions committed on the old primary are durable at the new primary before failover begins. **Caveat**: `semiSyncAckTimeout: 10s` (configured in `mariadb.yaml`) bounds how long the primary will wait for the ACK. If the replica is unreachable past that budget, mariadb falls back to asynchronous replication for subsequent commits — writes committed during that fallback window can be lost if the primary fails before replication catches up. Operators with stricter durability requirements can tune the timeout higher (trading rare async-fallback for higher write latency during replica blips) or layer Galera for synchronous multi-master.

Alternative stacks that satisfy the same three-part contract would also work: MaxScale or ProxySQL in front of a hand-rolled StatefulSet, [Orchestrator](https://github.com/openark/orchestrator), Galera for synchronous multi-master. The Operator is this stack's choice because it manages the full cluster declaratively (StatefulSet, Services, TLS via cert-manager, backup wiring) rather than requiring multiple components to cooperate.

### CA rotation is a separate concern

The `ca-key-pair` Secret (CA cert + private key, 10y duration on `certs/ca-certificate.yaml`) is NOT annotated for reload: rotating the CA invalidates every trusted-CA list downstream peers hold, which requires an overlap period where both the old and new CA are trusted simultaneously. **cert-manager behavior**: `certs/ca-certificate.yaml` sets `renewBefore: 360h` (~15 days) explicitly — if that field were unset, cert-manager's default is 2/3 of the certificate lifetime, which for a 10y CA would be ~3⅓ years before expiry. cert-manager 1.20 rotates the CA private key by default on each renewal (`rotationPolicy: Always`) — which is what makes it a key rotation and not just a cert refresh. **What does NOT happen automatically**: existing leaf Certificates DO NOT get re-issued on a CA key rotation. They continue to be valid until their own `renewBefore` triggers. **Danger**: a leaf cert that just renewed against the OLD CA shortly before the rotation could hold old-CA-signed material for its full duration (up to 168h / 7d). If the old CA expires inside that window, those certs become invalid.

**Operator procedure for CA rotation** (manual — the stack does not wire `trust-manager`, so steps 2 and 7 are the operator's responsibility):

1. **Schedule well before `renewBefore` hits.** Budget at least 2-3 weeks ahead so there's room for the full choreography including verification.
2. **Issue the replacement CA as an independent Certificate resource** (not by waiting for cert-manager to rotate `ca-key-pair` in place). Both CAs must exist side-by-side during the overlap window; distributing them through separate, independently-managed trust bundles avoids the trap below. **Also update `certs/ca-certificate.yaml` and `certs/ca-issuer.yaml` (and anything else `kub-up` re-applies) to reference the new CA**, otherwise re-running `kub-up` at any later point will reconverge to the old `ca-key-pair` / `ca-issuer` state and undo the rotation. The checked-in manifests are the source of truth `kub-up` reapplies on every invocation.
3. **Distribute BOTH old and new CA via peer trust bundles.** Do NOT use the `ca.crt` field inside any leaf cert Secret for staged dual-trust — cert-manager rewrites that field during every leaf renewal, so your carefully-staged dual-trust gets clobbered the next time any leaf renews. Trust bundles must be independent ConfigMaps/Secrets managed by the operator (or `trust-manager`).
4. **Wait for every peer to have reloaded both CAs** into its trust list. Workloads that mount the trust bundle via subPath may need an explicit rollout restart — don't assume pod startup picked up the update.
5. **Switch the `ca-issuer` Issuer to the new CA** so future leaf issuance is signed by the new CA.
6. **Force-renew every leaf Certificate** (`cmctl renew <cert>` for each) so none of them are still holding old-CA-signed material. Don't rely on natural `renewBefore` cadence — the force-renew ensures every leaf is signed by the new CA before the old CA expires.
7. **Verify the chain end-to-end before removing the old CA**, in this order:
   - a. Leaf Secret `tls.crt` fingerprint changed (proves cert-manager re-issued).
   - b. The workload that uses that cert has rolled (operator-managed workloads via the MariaDB Operator cert-controller; reloader-managed workloads via `kubectl rollout restart`'s event trail).
   - c. The handshake actually uses the new cert — exercise each cert's consumer path (`openemr → mysql-primary`, `phpmyadmin → mysql`, `openemr → redis`, etc.) and verify the client-observed chain. Secret fingerprint alone is NOT proof that the running process has loaded the new material — a slow pod or a stuck reload could still be serving the old cert.
8. **Only then** remove the old CA from trust bundles.

`trust-manager` is installed by `kub-up` into the `cert-manager` namespace (see `kubernetes/trust-manager/manifests.yaml` — vendored render of the upstream helm chart at v0.26.0). The install provides the `Bundle` CRD + controller; **no Bundles are shipped by default** because workloads in this stack currently consume CA material via each leaf cert's Secret-embedded `ca.crt`, which cert-manager refreshes as a side-effect of leaf-cert renewal. The Bundle resource becomes load-bearing specifically for the CA-rotation overlap: operators create a `Bundle` (cluster-scoped `trust.cert-manager.io/v1alpha1` resource) listing BOTH the old and new CAs as `sources`, with a target ConfigMap. trust-manager keeps that ConfigMap continuously in sync across every selected namespace, and rolls workloads via reloader annotations on the ConfigMap. This automates steps 3, 4, and 8 — the operator no longer has to hand-copy trust lists to every peer or coordinate the final old-CA removal across workloads. A worked example is in the [trust-manager Bundle docs](https://cert-manager.io/docs/trust/trust-manager/#bundles); the shape that fits this stack is a dual-source Bundle with an ingress-class namespaceSelector during overlap, trimmed to a single new-CA source after step 7's end-to-end verification.

> **Bundle source namespace caveat.** trust-manager by default only resolves `Bundle.spec.sources.secret` entries from its own trust-namespace (the `cert-manager` namespace in this install, matching the helm chart's `app.trust.namespace` default). The existing `ca-key-pair` Secret in this stack lives in the `default` namespace (same place as `ca-certificate.yaml`), so a Bundle referencing it will fail with a `Secret not found` condition until either (a) the operator copies the current CA + the new CA into Secrets inside the `cert-manager` namespace before creating the Bundle — simplest for a one-off rotation, or (b) the trust-manager install is reconfigured to resolve sources from the `default` namespace via the `app.trust.namespace` value (requires re-rendering `trust-manager/manifests.yaml` with `--set app.trust.namespace=default` and re-applying). Option (a) is the right default for an occasional CA rotation; option (b) is right for operators who want Bundle-driven trust distribution in steady state.

# Connection Security

The mTLS configuration above is the default. Both MariaDB and Redis connection security can be relaxed when a more limited threat model permits — for example, when running entirely within a single cluster on a hyperscaler whose infrastructure already provides wire encryption, or for development environments.

## MariaDB Connection Security
By default, MariaDB connections use **mTLS (mutual TLS)** with X509 client certificate verification for all connections (OpenEMR, phpMyAdmin, and replication). All certificates are managed by cert-manager. To downgrade the connection security:

Enforcement now lives on the `MariaDB` resource (`mysql/mariadb.yaml`), not on checked-in SQL files. The operator reads `spec.tls` and turns it into server-wide `require_secure_transport` / X509-required enforcement; the hand-rolled `mysql/configmap.yaml` with `primary.sql` / `secondary.sql` is gone — replication itself is now operator-managed. Replication cert material is likewise handled by the operator via `spec.replication` + `spec.tls`, so there is no `MASTER_SSL_*` wiring to edit.

> **Pre-existing account caveat.** OpenEMR's container bootstrap creates the `openemr` DB account with a `REQUIRE X509` clause on first boot, driven by `FORCE_DATABASE_X509_CONNECT`. Because that clause is set at `CREATE USER` time and lives on the per-account GRANT, changing the deployment env var later does NOT alter the existing account — the user will still `REQUIRE X509` and reject client-cert-less connections even after a server-side downgrade. The downgrade steps below include an explicit `ALTER USER … REQUIRE …` as the FIRST step on an already-bootstrapped cluster. Fresh installs that have never booted OpenEMR before can skip that step; the bootstrap will pick up the new env var on first run.

### Downgrade to TLS (encrypted, no client certs)
1. **On an already-bootstrapped cluster**, connect to MariaDB as a privileged account and run:
   ```sql
   ALTER USER 'openemr'@'%' REQUIRE SSL;
   -- If phpmyadmin's account was also created with REQUIRE X509, repeat for it.
   ```
2. `mysql/mariadb.yaml`: Under `spec.tls`, remove `clientCertIssuerRef` (leave `enabled: true` and `serverCertIssuerRef` — the server still presents a cert, but no longer requires clients to present one). The operator will reconcile the `MariaDB` resource on apply.
3. `openemr/deployment.yaml`: Change `FORCE_DATABASE_X509_CONNECT` to `FORCE_DATABASE_SSL_CONNECT` and remove the `tls.crt` (mysql-cert) and `tls.key` (mysql-key) items from the `mysql-openemr-client-certs` volume
4. `phpmyadmin/configmap.yaml`: Comment out or remove the `ssl_cert` and `ssl_key` lines
5. `phpmyadmin/deployment.yaml`: Remove the `tls.crt` and `tls.key` items from the `mysql-phpmyadmin-client-certs` volume

### Downgrade to TCP (no encryption)
Perform all the TLS downgrade steps above, then additionally:
1. **On an already-bootstrapped cluster**, connect to MariaDB as a privileged account and run:
   ```sql
   ALTER USER 'openemr'@'%' REQUIRE NONE;
   -- If phpmyadmin's account was altered in the TLS step, repeat for it.
   ```
2. `mysql/mariadb.yaml`: Set `spec.tls.enabled: false` (explicit disable is clearer than removing the whole block — operator still reconciles and emits an event confirming TLS is off). Leave or remove the issuerRef fields; `enabled: false` is what the operator keys on.
3. `openemr/deployment.yaml`: Remove the `FORCE_DATABASE_SSL_CONNECT` environment variable and remove the entire `mysql-openemr-client-certs` volume and volumeMount
4. `phpmyadmin/configmap.yaml`: Set `ssl` to `false`, remove `ssl_ca`, and remove `ssl_verify`
5. `phpmyadmin/deployment.yaml`: Remove the entire `mysql-phpmyadmin-client-certs` volume and volumeMount
6. `certs/mysql-openemr-client.yaml`, `certs/mysql-phpmyadmin-client.yaml`: These cert-manager Certificate resources can be removed entirely (operator-managed server/internal-client certs are already covered by step 2 above)
7. `kub-up` and `kub-down` (and `.bat` variants): Remove the mysql client-cert references (operator-managed cert files no longer exist on the `spec.tls.enabled: false` path)

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

## Upgrading an existing site from the hand-rolled mysql StatefulSet

This layout uses the MariaDB Operator (declarative cluster via `MariaDB` CRD) instead of the pre-rel-860 hand-rolled `mysql-sts` StatefulSet + headless Service. `kub-up` refuses to apply the operator manifests on a cluster that still has an old-layout `mysql-sts` StatefulSet, because a safe hot cutover requires three things kub-up can't automate reliably: writes quiesced on the application side, DB migrated to the new topology, and openemr clients repointed from the old `mysql` Service to the new `mysql-primary`. Attempting that in-script risks leaving the site unreachable mid-upgrade.

**Fresh-cluster migration is strongly recommended** — not a namespace on the same cluster. This stack's cluster-wide resources (cert-manager, trust-manager, reloader, mariadb-operator, csi-driver-nfs, StorageClass `nfs`) are installed once per cluster by `kub-up`; a second namespace cannot run its own copies, and the existing NFS stack binds node-local stunnel-client sockets that a second namespace would collide with. If you MUST do namespace-coexistence, you'll need manual rewiring of the second namespace's NFS and port allocation outside the scope of this README.

Supported upgrade procedure:

1. **On the existing site, quiesce writes:**
   ```bash
   kubectl scale deployment/openemr --replicas=0
   kubectl scale deployment/phpmyadmin --replicas=0
   ```
   Wait for pods to terminate. Keep them at `replicas=0` through the entire migration — any running openemr pod could reconnect and write to the old DB, invalidating the snapshot you're about to take.
2. **Back up ALL three shared volumes off-cluster**, not just the DB:
   - **DB**: logical dump via `mysqldump --all-databases --single-transaction --routines --triggers > dump.sql` from inside a shell in `mysql-sts-0`. (The operator-managed destination accepts a `mysql` client restore through `mysql-primary`; `mariadb-backup` physical backups are NOT drop-in restorable this way and need a different workflow — operator-managed `MariadbBackup`/`MariadbRestore` CRs, or a bootstrapFrom configuration on the new MariaDB resource — so logical dump is the safer default here.)
   - **websitevolume** (`/var/www/.../sites`): openemr-managed documents, encounter-attached files, OpenEMR module state. Snapshot the PVC to an off-cluster location via a short-lived busybox helper pod (same pattern as the CSI-NFS upgrade section below).
   - **sslvolume** (`/etc/ssl`) and **letsencryptvolume** (`/etc/letsencrypt`) if the site has operator-provisioned TLS cert material worth keeping.
3. **Spin up a fresh cluster** and run `kub-up` there. The operator-managed MariaDB will come up empty.
4. **Keep the new site's `openemr` Deployment at `replicas=0`** before restoring (`kubectl scale deployment/openemr --replicas=0` on the new cluster). Letting openemr boot against an empty DB risks running `install_simple.php` and re-seeding tables you're about to restore over.
5. **Restore the DB dump** into the new cluster:
   ```bash
   kubectl exec -i deploy/openemr -- mysql -h mysql-primary -u root -p < dump.sql
   ```
   (or similar — adjust for your off-cluster dump location). Verify tables populated via phpmyadmin on the new cluster.
6. **Restore the backed-up websitevolume / sslvolume / letsencryptvolume contents** into the new cluster's PVCs (helper-pod `tar -x` into each mount, same reverse of step 2's snapshot).
7. **Scale openemr back up** on the new cluster (`kubectl scale deployment/openemr --replicas=3`) and verify end-to-end: login, patient operations, FHIR endpoints, document retrieval from the restored websitevolume.
8. **Cut traffic over to the new site's ingress** once verified (DNS flip, load-balancer repointing, or whatever your ingress layer uses).
9. **Decommission the old site on its own cluster**. Do NOT run `kub-down` if you reused the same cluster — it would tear down cluster-wide operators (cert-manager, mariadb-operator, etc.) that the old site also depends on, and there isn't a namespace-only teardown path in this stack today. On a dedicated-cluster migration, the full `kub-down` on the old cluster is the right teardown.

Doing it as fresh-cluster + dump/restore is slower than in-place but is the safe path on a schema that touches every workload. Operators comfortable with mariadb replication can also set up the new operator cluster as a replica of the old primary, promote it, and cut over — but that's bring-your-own-expertise territory; this README doesn't walk through it.

## Upgrading an existing cluster to the CSI-based NFS stack

This stack does not support in-place upgrades for the Kubernetes side — the storage layer and manifest wiring are redone whole-cluster. If you have an existing cluster running the older sig-storage/nfs-provisioner setup (pre-#910), the upgrade path is:

1. **Quiesce application writes first.** `kubectl scale deployment/openemr --replicas=0` and `kubectl scale deployment/phpmyadmin --replicas=0` before anything else, and wait for the pods to terminate. Without this, documents written between the export and `kub-down` are absent from the restored volume.
2. **Preserve all three RWX volumes via a helper pod.** `kub-down` destroys `websitevolume`, `sslvolume`, and `letsencryptvolume` — not just `websitevolume`. With openemr scaled to zero in step 1, there is no running pod that mounts the claims, so bring up a short-lived helper that does:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata: { name: backup-helper }
   spec:
     containers:
     - name: backup
       image: busybox
       command: ["sleep", "3600"]
       volumeMounts:
       - { name: web, mountPath: /backup/websitevolume }
       - { name: ssl, mountPath: /backup/sslvolume }
       - { name: le,  mountPath: /backup/letsencryptvolume }
     volumes:
     - { name: web, persistentVolumeClaim: { claimName: websitevolume } }
     - { name: ssl, persistentVolumeClaim: { claimName: sslvolume } }
     - { name: le,  persistentVolumeClaim: { claimName: letsencryptvolume } }
   ```

   Then `kubectl cp backup-helper:/backup/websitevolume ./websitevolume-backup` (and likewise for `sslvolume`, `letsencryptvolume`). Delete the helper (`kubectl delete pod backup-helper`) before step 3 so it does not hold the claims open against `kub-down`.
3. **`bash kub-down`** on the old manifests — fully tears down the old nfs-provisioner Deployment, Service, and RBAC along with the rest of the stack, so no plaintext NFS provisioner is left behind.
4. **Pull the updated manifests** (this branch / release).
5. **`bash kub-up`** on the new manifests. The new `nfs-server` Deployment, csi-driver-nfs, stunnel pods, and mTLS certs come up from scratch.
6. **Restore each volume into its newly-provisioned CSI subdirectory.** csi-driver-nfs auto-names each RWX volume's backing directory as `<pvc-name>-<uid>` under `/nfsshare` on the backing PV (or under the share root for cloud-managed NFS). Restore into any openemr replica — only openemr mounts these claims, and all replicas share them. Stream the backup directory's *contents* (not the directory itself, which `kubectl cp` would nest) with tar:

   ```
   tar cf - -C websitevolume-backup . | kubectl exec -i $(kubectl get pod -l name=openemr -o jsonpath='{.items[0].metadata.name}') -- tar xf - -C /var/www/localhost/htdocs/openemr/sites
   tar cf - -C sslvolume-backup       . | kubectl exec -i $(kubectl get pod -l name=openemr -o jsonpath='{.items[0].metadata.name}') -- tar xf - -C /etc/ssl
   tar cf - -C letsencryptvolume-backup . | kubectl exec -i $(kubectl get pod -l name=openemr -o jsonpath='{.items[0].metadata.name}') -- tar xf - -C /etc/letsencrypt
   ```

   The kubelet routes writes through the mount transparently into the newly-provisioned CSI directory. (Advanced: pre-create static PVs with `persistentVolume.spec.nfs.path` pointing at the pre-existing backup directories and bind the PVCs to those, which skips the auto-provision step entirely. A static PV does *not* inherit the StorageClass's `mountOptions`, so each one must set `spec.nfs.server: 127.0.0.1` and `spec.mountOptions: [nfsvers=4.0, port=12049, noac, actimeo=0]` explicitly — otherwise the mount fails.)

Attempting to apply the new manifests on top of an old cluster without a `kub-down` first will leave the old nfs-provisioner running alongside the new csi-driver-nfs, and the StorageClass `parameters` are immutable so the old `provisioner: cluster.local/nfs-provisioner` will not be replaced by the new `nfs.csi.k8s.io` provisioner — a silent half-upgrade state.

## Encryption at rest (storage layer)

The simplest path to encryption-at-rest is to back the persistent volumes with an encrypted StorageClass at the cloud or storage-layer. Two PVCs matter:

- **MariaDB `datadir`** (RWO) — set `spec.storage.storageClassName` on the `MariaDB` resource in `mysql/mariadb.yaml` to your encrypted StorageClass. The operator renders this into the generated StatefulSet's `volumeClaimTemplates`.
- **NFS server backing** (RWO) — set `storageClassName` on `nfs/nfs-server-pvc.yaml` to your encrypted StorageClass. The three RWX volumes (`websitevolume`, `sslvolume`, `letsencryptvolume`) consumed by openemr/phpmyadmin are provisioned as subdirs under this one backing PV by csi-driver-nfs, so they all inherit the backing disk's encryption; no changes to OpenEMR manifests are needed.

| Cloud / Environment | StorageClass | Key management |
|---|---|---|
| AWS / EKS | `gp3` with `encrypted: "true"` | AWS KMS (CMK or AWS-managed) |
| GCP / GKE | `pd-balanced` or `pd-ssd` with `disk-encryption-kms-key` | Cloud KMS / CMEK |
| Azure / AKS | `managed-csi` with `diskEncryptionSetID` | Azure Disk Encryption Set |
| On-prem (self-hosted) | Longhorn with `encrypted: "true"` | dm-crypt key in Kubernetes Secret |
| On-prem (Ceph) | Rook/Ceph with `encrypted: "true"` | dm-crypt or Vault |

Storage-layer encryption protects against stolen disks, decommissioned media, snapshot exfiltration, and backup-tape theft. It does not protect against attackers who have access to the running cluster (pods see plaintext through the mounted filesystem).

### Option 2 — in-pod encryption over NFS (two variants)

For threat models where that plaintext exposure matters — a compromised NFS server pod is in-scope, the backing-storage operator is not trusted to never read on-disk blocks, or regulatory posture requires application-layer encryption with keys the storage operator cannot access — two working examples are shipped under `kubernetes/examples/`. Both keep keys inside the openemr pod, so the NFS server pod and the backing disk only ever see ciphertext. They trade off along a different axis from each other, so pick the one that matches your constraints.

**Option 2a — in-pod LUKS over NFS** (`examples/encryption-at-rest-luks/`). The openemr pod wraps `websitevolume` in a LUKS container file. The NFS backing sees exactly one opaque blob — file counts, sizes, and access patterns per plaintext file are all hidden. **Trade-off:** LUKS wraps a single ext4 filesystem that is single-writer, so adoption requires scaling the openemr Deployment from 3 replicas to 1 (the default stack's `strategy: Recreate` is retained, which this example makes safe single-replica rather than merely sequential multi-replica). Pick this when you need maximum metadata hiding and can accept single-replica openemr.

**Option 2b — in-pod gocryptfs over NFS** (`examples/encryption-at-rest-gocryptfs/`). The openemr pod transparently encrypts each file individually via gocryptfs in `-sharedstorage` mode. The NFS backing sees per-file ciphertext with encrypted filenames (operators see `5NOxPYSqKQ4=` instead of `sqlconf.php`), but file count and per-file ciphertext sizes do leak. **Trade-off:** more metadata is visible on NFS than Option 2a, but the default stack's `replicas: 3` is preserved AND the rollout strategy changes from the default's `Recreate` to `RollingUpdate` for zero-downtime rolls — concurrent mounts across pods are safe because gocryptfs stores each file as its own ciphertext file and `-sharedstorage` disables metadata caching that would otherwise go stale across pods. Pick this when you need multi-replica openemr and can accept the filename-cardinality / per-file-size metadata leak.

Both variants require a `privileged: true` sidecar (LUKS needs `dm-crypt` + loop; gocryptfs needs `/dev/fuse` + `CAP_SYS_ADMIN`) while keeping the main openemr container unprivileged. Each example's README documents the full trade-off matrix, a step-by-step adoption and rollback procedure, and a key-rotation runbook. Options 1 and 2 are not mutually exclusive — running Option 1 under either Option 2 variant as defense-in-depth is valid.

## MariaDB Transparent Data Encryption (TDE)

For defense-in-depth beyond storage-layer encryption, MariaDB's built-in `file_key_management` plugin encrypts InnoDB tablespaces, redo logs, binary logs, and temp files at the application layer. The plugin ships in the stock `mariadb:11.8.6` image used by this stack — no custom image is required.

Enabling TDE involves editing the `MariaDB` resource in `mysql/mariadb.yaml` (the operator-managed cluster — the pre-rel-860 hand-rolled StatefulSet + ConfigMap this section used to reference is gone):

1. **A new Secret** containing the keyfile (one or more lines of `<key-id>;<32 hex chars = 16-byte AES key>`), optionally itself encrypted with a master password supplied via `file_key_management_filekey`.
2. **A pod-template volume mount** on the MariaDB pods at `/etc/mysql/encryption/`, added under `spec.podTemplate.spec.containers[?(@.name=="mariadb")].volumeMounts` and `spec.podTemplate.spec.volumes` on the `MariaDB` resource. Source the secret with `defaultMode: 0400`. The operator renders the podTemplate into both primary and replica pods, so the keyfile is automatically consistent across replication.
3. **mysqld configuration additions** via `spec.myCnf` on the `MariaDB` resource — the operator writes this string into a managed ConfigMap that's mounted on both primary and replica pods. Keep the existing `spec.myCnf` content if any; append:
   ```yaml
   spec:
     myCnf: |
       # ... existing lines (if any) ...
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

Enable TDE at first boot so the system tablespace is born encrypted. Existing tables are encrypted in the background by `innodb_encryption_threads`.

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
| AWS EFS | `fs-xxxx.efs.<region>.amazonaws.com` (EFS DNS name) | `/` | `4.1` (EFS speaks 4.1) | drop `port=12049` (EFS listens on default 2049) | Delete in-cluster NFS files + their references in `kub-up` / `kub-down`. Mounting EFS from csi-driver-nfs is unencrypted on the wire by default — see the encryption-in-transit section below. |
| GCP Filestore | Filestore instance IP | Filestore file-share name (e.g. `/vol1`) | `4.1` (Filestore Basic is 3, Enterprise/Zonal is 4.1 — pick the tier with 4.1) | drop `port=12049` | Same deletions as EFS. See encryption notes below. |
| Azure Files (NFS 4.1) | storage-account FQDN (e.g. `myacct.file.core.windows.net`) | share path (e.g. `/myacct/share1`) | `4.1` (Azure Files NFS only speaks 4.1) | drop `port=12049` | Same deletions as EFS. See encryption notes below. |
| On-prem managed NFS | NFS appliance IP or DNS name | the appliance's export path | match the appliance's supported minor version | drop `port=12049` unless the appliance listens on it | Same deletions as EFS. The stunnel-client DaemonSet becomes dead code once `server` is anything other than `127.0.0.1` — the DaemonSet listens only on the node loopback, and csi-driver-nfs's mount now dials the external appliance directly. Plan a separate encrypted transport (e.g. IPsec tunnel between the Kubernetes nodes and the NFS appliance, or NFSv4-with-Kerberos). |

**Important: StorageClass `parameters` and `mountOptions` are immutable.** Kubernetes rejects edits to either field on an existing StorageClass, and existing PVs retain whatever values they were originally provisioned with. The clean migration path is `kub-down` → wait for cluster-level teardown → edit `storageclass.yaml` → `kub-up`. For a cluster that has live patient data on the in-cluster NFS backing: scale openemr/phpmyadmin to zero first (to quiesce writes), export each of the three RWX volumes (`websitevolume`, `sslvolume`, `letsencryptvolume`), `kub-down`, swap the StorageClass to the cloud endpoint, `kub-up`, then restore each export into the CSI-provisioned subdirectory the new PVC creates under the cloud share. See the upgrade section above for the full sequence.

**Encryption-in-transit on the cloud path.** The default `nfs` StorageClass uses the kernel NFS client — it does not auto-negotiate TLS to the server. The in-cluster stunnel-client DaemonSet only wraps traffic because `parameters.server` points at `127.0.0.1`, which routes through the local DaemonSet pod. Once `parameters.server` is changed to any external endpoint, csi-driver-nfs's kubelet mount dials the external address directly and the DaemonSet becomes unused — the mount is plaintext regardless of whether the DaemonSet exists. The cloud path's encryption therefore depends entirely on the mount endpoint, not on anything we deploy inside the cluster. By cloud:

- **AWS EFS**: the supported encryption-in-transit path is `efs-utils` with the `-o tls` option, which spawns a local stunnel-equivalent on each node and wraps traffic to EFS. csi-driver-nfs does **not** use `efs-utils`, so a direct `nfs.csi.k8s.io` → EFS mount is plaintext on the wire. Options: replace csi-driver-nfs with the `aws-efs-csi-driver` (which does use `efs-utils` under the hood and accepts `encryptInTransit: "true"` as a mount option), or front csi-driver-nfs with your own node-local stunnel layer analogous to the in-cluster pattern this stack uses. (Nitro-based instance-to-instance encryption is sometimes cited as an alternative, but it's limited to specific instance types and placement conditions — not a reliable blanket property. Don't rely on it without reviewing the current AWS docs for your exact instance family.)
- **GCP Filestore**: supports NFSv4.1 encryption-in-transit via Kerberos (`sec=krb5p`), which requires a Kerberos KDC the nodes can reach and client principal/keytab config on each node — not a `csi-driver-nfs` mountOption. Without Kerberos, the mount is plaintext on the wire. (`fscrypt` is a Linux at-rest FS encryption feature and `gcsfuse` mounts Cloud Storage buckets rather than Filestore, so neither applies here.)
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
