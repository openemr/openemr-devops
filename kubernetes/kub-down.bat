@echo off

REM Teardown counterpart to kub-up.bat. See kub-down for the full
REM shape rationale.

kubectl delete ^
    -f certs/ca-bundle.yaml ^
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

REM MariaDB resource first (operator cleans up StatefulSet + Services
REM + its own cert-manager Certificates on resource deletion), then
REM the credential Secrets, then the operator itself.
kubectl delete ^
    -f mysql/mariadb.yaml ^
    -f mysql/secret.yaml ^
    -f mysql/replication-secret.yaml

kubectl delete -f https://github.com/mariadb-operator/mariadb-operator/releases/download/mariadb-operator-26.10.2/manifests.min.yaml

REM stakater/reloader (installed by kub-up.bat).
kubectl delete -f https://raw.githubusercontent.com/stakater/Reloader/v1.4.23/deployments/kubernetes/reloader.yaml

REM trust-manager (installed by kub-up.bat from vendored manifest).
REM Deleted BEFORE cert-manager — its webhook depends on a
REM cert-manager Certificate; deleting cert-manager first wedges
REM Bundle finalizers.
kubectl delete -f trust-manager/manifests.yaml

REM cert-manager (installed by kub-up.bat).
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml

kubectl delete ^
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

kubectl delete ^
    -f nfs/stunnel-client-daemonset.yaml ^
    -f nfs/stunnel-client-configmap.yaml ^
    -f nfs/nfs-server-deployment.yaml ^
    -f nfs/nfs-server-stunnel-configmap.yaml ^
    -f nfs/nfs-server-ganesha-configmap.yaml ^
    -f nfs/nfs-server-service.yaml ^
    -f nfs/nfs-server-pvc.yaml ^
    -f nfs/storageclass.yaml

kubectl delete ^
    -f csi-nfs/csi-nfs-node.yaml ^
    -f csi-nfs/csi-nfs-controller.yaml ^
    -f csi-nfs/csi-nfs-driverinfo.yaml ^
    -f csi-nfs/rbac-csi-nfs.yaml
