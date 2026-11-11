@echo off

kubectl wait --for=condition=Ready nodes --all --timeout=120s

REM Pre-flight guard against upgrading an in-place pre-rel-860 site.
REM Run FIRST so an old-layout site aborts before any cluster-wide
REM installs. Fail-closed: distinguish "StatefulSet not found" from
REM other kubectl errors (API server unreachable, RBAC denial,
REM wrong context). Treating all non-zero returns as "proceed" would
REM silently install the operator stack even when the lookup never
REM reached the cluster. See kubernetes/README.md "Upgrading an
REM existing site" for the dump+restore procedure.
kubectl get statefulset/mysql-sts > "%TEMP%\mysql-sts-lookup.out" 2>&1
SET MYSQL_STS_LOOKUP_RC=%ERRORLEVEL%
IF %MYSQL_STS_LOOKUP_RC% EQU 0 (
    echo ERROR: Existing 'mysql-sts' StatefulSet found - this layout uses the MariaDB Operator
    echo        and cannot upgrade an existing hand-rolled cluster in place. See the README's
    echo        'Upgrading an existing site' section for the dump+restore procedure. Aborting.
    del "%TEMP%\mysql-sts-lookup.out" 2>nul
    exit /b 1
)
findstr /I /R "not.found NotFound" "%TEMP%\mysql-sts-lookup.out" >nul 2>&1
IF NOT %ERRORLEVEL% EQU 0 (
    echo ERROR: Pre-flight check failed - unable to query the cluster for an existing 'mysql-sts'
    echo        StatefulSet. kubectl reported:
    type "%TEMP%\mysql-sts-lookup.out"
    echo        Resolve the API/RBAC/context issue and re-run kub-up. Aborting.
    del "%TEMP%\mysql-sts-lookup.out" 2>nul
    exit /b 1
)
del "%TEMP%\mysql-sts-lookup.out" 2>nul

REM bring in cert-manager (the NFS mTLS layer below requires it)
REM
REM github.com's release-download endpoint occasionally returns 504
REM Gateway Timeout under load (observed persistently in CI on
REM 2026-11-08). kubectl apply is idempotent on this manifest so
REM retrying is safe. 3 attempts; linear backoff via timeout(1).
set CERT_MANAGER_ATTEMPTS=0
:cert_manager_retry
set /a CERT_MANAGER_ATTEMPTS+=1
kubectl apply --validate=false -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
if %errorlevel%==0 goto cert_manager_applied
if %CERT_MANAGER_ATTEMPTS% geq 3 (
    echo ERROR: cert-manager apply failed after 3 attempts.
    echo Check https://www.githubstatus.com and retry.
    exit /b 1
)
echo ...cert-manager apply attempt %CERT_MANAGER_ATTEMPTS% failed; retrying...
REM Use `ping` as a portable 20-second delay. `timeout` requires a TTY
REM and fails silently when the script's stdin is redirected (e.g.
REM `kub-up.bat < some-input` or CI non-interactive runs).
REM `ping -n 21 127.0.0.1 >nul` waits ~20s (first ping is immediate,
REM subsequent 20 are 1s apart).
ping -n 21 127.0.0.1 >nul
goto cert_manager_retry
:cert_manager_applied
kubectl wait --for=condition=Available --timeout=120s -n cert-manager deployment/cert-manager-webhook
timeout 15

REM bring in trust-manager (cert-manager sibling for Bundle-driven CA
REM distribution during CA rotation). Vendored manifest — see
REM kubernetes/trust-manager/manifests.yaml for provenance. Depends on
REM cert-manager being up.
set TRUST_MANAGER_ATTEMPTS=0
:trust_manager_retry
set /a TRUST_MANAGER_ATTEMPTS+=1
kubectl apply --server-side=true --force-conflicts -f trust-manager/manifests.yaml
if %errorlevel%==0 goto trust_manager_applied
if %TRUST_MANAGER_ATTEMPTS% geq 3 (
    echo ERROR: trust-manager apply failed after 3 attempts.
    exit /b 1
)
echo ...trust-manager apply attempt %TRUST_MANAGER_ATTEMPTS% failed; retrying...
ping -n 21 127.0.0.1 >nul
goto trust_manager_retry
:trust_manager_applied
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment/trust-manager

REM bring in stakater/reloader (same shape as cert-manager retry above).
REM Rolls cert-consuming workloads when cert-manager rotates their
REM Secrets. See kubernetes/README.md -> Certificate reload mechanism.
set RELOADER_ATTEMPTS=0
:reloader_retry
set /a RELOADER_ATTEMPTS+=1
kubectl apply -f https://raw.githubusercontent.com/stakater/Reloader/v1.4.23/deployments/kubernetes/reloader.yaml
if %errorlevel%==0 goto reloader_applied
if %RELOADER_ATTEMPTS% geq 3 (
    echo ERROR: reloader apply failed after 3 attempts.
    echo Check https://www.githubstatus.com and retry.
    exit /b 1
)
echo ...reloader apply attempt %RELOADER_ATTEMPTS% failed; retrying...
ping -n 21 127.0.0.1 >nul
goto reloader_retry
:reloader_applied
kubectl wait --for=condition=Available --timeout=120s deployment/reloader-reloader

REM bring in MariaDB Operator (same shape as cert-manager / reloader retry).
REM Manages the mysql StatefulSet + Services + replication + automatic
REM failover via the MariaDB CRD — replaces the hand-rolled mysql
REM topology with a properly HA one. See kubernetes/mysql/mariadb.yaml
REM and kubernetes/README.md -> Certificate reload mechanism.
set MARIADB_OP_ATTEMPTS=0
:mariadb_op_retry
set /a MARIADB_OP_ATTEMPTS+=1
kubectl apply --server-side=true --force-conflicts -f https://github.com/mariadb-operator/mariadb-operator/releases/download/mariadb-operator-26.10.2/manifests.min.yaml
if %errorlevel%==0 goto mariadb_op_applied
if %MARIADB_OP_ATTEMPTS% geq 3 (
    echo ERROR: MariaDB Operator apply failed after 3 attempts.
    echo Check https://www.githubstatus.com and retry.
    exit /b 1
)
echo ...MariaDB Operator apply attempt %MARIADB_OP_ATTEMPTS% failed; retrying...
ping -n 21 127.0.0.1 >nul
goto mariadb_op_retry
:mariadb_op_applied
kubectl wait --for=condition=Available --timeout=180s deployment/mariadb-operator
kubectl wait --for=condition=Available --timeout=180s deployment/mariadb-operator-cert-controller
kubectl wait --for=condition=Available --timeout=180s deployment/mariadb-operator-webhook

kubectl apply ^
    -f certs/selfsigned-issuer.yaml ^
    -f certs/ca-certificate.yaml ^
    -f certs/ca-issuer.yaml ^
    -f certs/mysql-openemr-client.yaml ^
    -f certs/phpmyadmin.yaml ^
    -f certs/mysql-phpmyadmin-client.yaml ^
    -f certs/redis.yaml ^
    -f certs/redis-openemr-client.yaml ^
    -f certs/sentinel.yaml ^
    -f certs/nfs-server.yaml ^
    -f certs/nfs-client.yaml
timeout 15

REM install csi-driver-nfs (StorageClass provisioner; upstream v4.13.6)
kubectl apply ^
    -f csi-nfs/rbac-csi-nfs.yaml ^
    -f csi-nfs/csi-nfs-driverinfo.yaml ^
    -f csi-nfs/csi-nfs-controller.yaml ^
    -f csi-nfs/csi-nfs-node.yaml

REM bring up the mTLS-wrapped in-cluster NFS stack
kubectl apply ^
    -f nfs/nfs-server-pvc.yaml ^
    -f nfs/nfs-server-service.yaml ^
    -f nfs/nfs-server-ganesha-configmap.yaml ^
    -f nfs/nfs-server-stunnel-configmap.yaml ^
    -f nfs/nfs-server-deployment.yaml ^
    -f nfs/stunnel-client-configmap.yaml ^
    -f nfs/stunnel-client-daemonset.yaml ^
    -f nfs/storageclass.yaml

REM ConfigMap updates via `subPath` mount do not propagate to running pods.
REM Trigger a rollout restart on both the nfs-server Deployment and the
REM nfs-stunnel-client DaemonSet so re-running kub-up with ConfigMap edits
REM actually takes effect.
kubectl rollout restart deployment/nfs-server
kubectl rollout restart daemonset/nfs-stunnel-client
REM Both have readinessProbes, so `rollout status` blocks on the
REM probes actually succeeding — real wait, not a pod-count check.
kubectl rollout status deployment/nfs-server --timeout=180s
kubectl rollout status daemonset/nfs-stunnel-client --timeout=180s

kubectl apply ^
    -f mysql/secret.yaml ^
    -f mysql/replication-secret.yaml ^
    -f mysql/mariadb.yaml ^
    -f redis/secret.yaml ^
    -f redis/configmap-main.yaml ^
    -f redis/configmap-acl.yaml ^
    -f redis/statefulset-redis.yaml ^
    -f redis/statefulset-sentinel.yaml ^
    -f redis/service-redis.yaml ^
    -f redis/service-sentinel.yaml ^
    -f phpmyadmin/configmap.yaml ^
    -f phpmyadmin/deployment.yaml ^
    -f phpmyadmin/service.yaml ^
    -f volumes/letsencrypt.yaml ^
    -f volumes/ssl.yaml ^
    -f volumes/website.yaml ^
    -f openemr/secret.yaml ^
    -f openemr/deployment.yaml ^
    -f openemr/service.yaml ^
    -f network/policies.yaml
