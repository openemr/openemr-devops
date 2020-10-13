# Overview
OpenEMR Kubernetes orchestration on Minikube. Creates 5 instances of OpenEMR with 1 instance of MariaDB, Redis, and phpMyAdmin. Would not consider it production quality, but will be a good working, starting point, and hopefully open the door to a myriad of other kubernetes based solutions. Note this is not supported by 5.0.2 docker, which is why it defaults to using the 6.0.0-dev docker. If wish to use the most recent codebase rather than 6.0.0-dev docker, then can change from openemr/openemr:6.0.0 to openemr/openemr:flex in the openemr-deployment.yaml script (note this will take much longer to start up (probably at least 10 minutes and up to 90 minutes) and is more cpu intensive since each instance of OpenEMR will download codebase and build separately).

# Use
1. Install (and then start) Kubernetes with Minikube: https://kubernetes.io/docs/setup/learning-environment/minikube/
2. To start OpenEMR orchestration:
    ```bash
    bash kub-up
    ```
3. Can see pod progress with following command:
    ```bash
    kubectl get pod
    ```
      - It will look something like this:
          ```console
          NAME                          READY   STATUS    RESTARTS   AGE
          mysql-565f988976-np9zs        1/1     Running   0          133m
          openemr-5f6db6c87c-8xgzq      1/1     Running   0          133m
          openemr-5f6db6c87c-bfktf      1/1     Running   0          133m
          openemr-5f6db6c87c-bwzdr      1/1     Running   0          133m
          openemr-5f6db6c87c-qn5ll      1/1     Running   0          133m
          openemr-5f6db6c87c-znq8h      1/1     Running   0          133m
          phpmyadmin-78968d6cfb-cdfmq   1/1     Running   0          133m
          redis-74cc9d667-5ltbq         1/1     Running   0          133m
          ```
4. Can see the service listing with following command:
    ```bash
    kubectl get svc
    ```
      - It will look something like this:
          ```console
          NAME         TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)                         AGE
          kubernetes   ClusterIP   10.96.0.1        <none>        443/TCP                         151m
          mysql        ClusterIP   10.109.255.180   <none>        3306/TCP                        147m
          openemr      NodePort    10.104.48.53     <none>        8080:31314/TCP,8090:30613/TCP   147m
          phpmyadmin   NodePort    10.97.77.18      <none>        8081:30571/TCP                  147m
          redis        ClusterIP   10.98.24.148     <none>        6379/TCP                        147m
          ```
5. Can get the link to go to OpenEMR with following command (use the top link for http and bottom link for https):
    ```bash
    minikube service openemr --url
    ```
      - It will look something like this:
          ```console
          http://192.168.99.100:31314
          http://192.168.99.100:30613
          ```
6. Can get the link to go to phpMyAdmin with following command:
    ```bash
    minikube service phpmyadmin --url
    ```
      - It will look something like this:
          ```console
          http://192.168.99.100:30571
          ```
7. Some cool replicas stuff. The OpenEMR docker pods are run as a replica set (since it is set to 5 replicas in this OpenEMR deployment script). Gonna cover how to view the replica set and how to change the number of replicas on the fly in this step.
    - First. lets list the replica set like this:
        ```bash
        kubectl get rs
        ```
        - It will look something like this (note OpenEMR has 5 desired and 5 current replicas going):
            ```console
            NAME                    DESIRED   CURRENT   READY   AGE
            mysql-64449b8cf7        1         1         1       4m5s
            openemr-5f6db6c87c      5         5         5       4m5s
            phpmyadmin-78968d6cfb   1         1         1       4m5s
            redis-74cc9d667         1         1         1       4m5s
            ```
    - Second, lets decrease OpenEMR's replicas from 5 to 2 (ie. pretend in an environment where don't need to expend resources of offering 5 replicas, perhaps after hours)
        ```bash
        kubectl scale deployment.v1.apps/openemr --replicas=2
        ```
        - It will return the following:
            ```console
            deployment.apps/openemr scaled
            ```
        - Now, there are only 2 replicas of OpenEMR instead of 5. Enter the `kubectl get rs` and `kubectl get pod` to see what happened.
    - Third, lets increase OpenEMR's replicas from 2 to 10 (ie. pretend in an environment where a huge number of OpenEMR users are using the system at the same time)
        ```bash
        kubectl scale deployment.v1.apps/openemr --replicas=10
        ```
        - It will return the following:
            ```console
            deployment.apps/openemr scaled
            ```
        - Now, there are 10 replicas of OpenEMR instead of 2. Enter the `kubectl get rs` and `kubectl get pod` to see what happened.
    - This is just a quick overview of scaling. Note we just did manual scaling in the example above, but there are also options of automatic scaling for example depending on cpu use etc.
8. To stop and remove OpenEMR orchestration (this will delete everything):
    ```bash
    bash kub-down
    ```

# Development notes
How this was built.
1. Downloaded the OpenEMR Docker Swarm example as docker-compose.yml (kept this modified script for historical purposes): https://gist.github.com/bradymiller/980086836af187285bf28b8db9eecabc
2. Made following changes in above file:
    - mysql need to change utf8 to utf8mb4
    - change openemr/openemr:5.0.2 to openemr/openemr:6.0.0
3. Ran Kompose on the above script
4. Made changes to openemr-deployment.yaml:
    - place quotes around all the environment values
5. Increased storage claims in the 3 volume claim scripts to be `1Gi` or `10Gi` (websitevolume)
6. Added mysql service and redis service scripts
7. Added type NodePort in OpenEMR and phpmyadmin service scripts
8. Changed PMA_HOSTS from mariadb to mysql in phpmyadmin deployment script
9. Changed mariadb:10.2 to mariadb:10.5 in mysql deployment script
