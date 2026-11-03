@echo off

kubectl wait --for=condition=Ready nodes --all --timeout=120s

REM bring in cert-manager (the NFS mTLS layer below requires it)
kubectl apply --validate=false -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=120s -n cert-manager deployment/cert-manager-webhook
timeout 15

kubectl apply ^
    -f certs/selfsigned-issuer.yaml ^
    -f certs/ca-certificate.yaml ^
    -f certs/ca-issuer.yaml ^
    -f certs/mysql.yaml ^
    -f certs/mysql-replication.yaml ^
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
REM Trigger a rollout restart so re-running kub-up with ConfigMap edits
REM actually takes effect (no-op on first apply).
kubectl rollout restart deployment/nfs-server
timeout 30

kubectl apply ^
    -f mysql/configmap.yaml ^
    -f mysql/secret.yaml ^
    -f mysql/replication-secret.yaml ^
    -f mysql/service.yaml ^
    -f mysql/statefulset.yaml ^
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
