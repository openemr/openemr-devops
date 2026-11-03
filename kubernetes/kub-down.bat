@echo off

kubectl delete ^
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

kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml

kubectl delete ^
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

kubectl delete ^
    -f nfs/stunnel-client-daemonset.yaml ^
    -f nfs/stunnel-client-configmap.yaml ^
    -f nfs/nfs-server-deployment.yaml ^
    -f nfs/nfs-server-stunnel-configmap.yaml ^
    -f nfs/nfs-server-service.yaml ^
    -f nfs/nfs-server-pvc.yaml ^
    -f nfs/storageclass.yaml

kubectl delete ^
    -f csi-nfs/csi-nfs-node.yaml ^
    -f csi-nfs/csi-nfs-controller.yaml ^
    -f csi-nfs/csi-nfs-driverinfo.yaml ^
    -f csi-nfs/rbac-csi-nfs.yaml
