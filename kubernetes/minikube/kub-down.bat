#!/bin/bash
kubectl delete -f websitevolume-persistentvolumeclaim.yaml ^
               -f sslvolume-persistentvolumeclaim.yaml ^
               -f letsencryptvolume-persistentvolumeclaim.yaml ^
               -f mysql-deployment.yaml ^
               -f mysql-service.yaml ^
               -f redis-deployment.yaml ^
               -f redis-service.yaml ^
               -f phpmyadmin-deployment.yaml ^
               -f phpmyadmin-service.yaml ^
               -f openemr-deployment.yaml ^
               -f openemr-service.yaml
