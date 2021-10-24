@echo off
kubectl delete ^
    -f mysql/secret.yaml ^
    -f mysql/deployment.yaml ^
    -f mysql/service.yaml ^
    -f redis/deployment.yaml ^
    -f redis/service.yaml ^
    -f phpmyadmin/deployment.yaml ^
    -f phpmyadmin/service.yaml ^
    -f volumes/letsencrypt.yaml ^
    -f volumes/ssl.yaml ^
    -f volumes/website.yaml ^
    -f openemr/secret.yaml ^
    -f openemr/deployment.yaml ^
    -f openemr/service.yaml 

