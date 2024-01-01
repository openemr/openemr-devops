# Overview
OpenEMR Kubernetes orchestration. Orchestration included OpenEMR, MariaDB, Redis, and phpMyAdmin.
  - OpenEMR - 3 deployment replications of OpenEMR are created. Replications can be increased/decreased. Ports for both http and https.
  - MariaDB - 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created. Replications can be increased/decreased which will increase/decrease number of replica/slaves. Connections are encrypted over the wire (ssl is enforced by default; X509 can be enforced by following pertinent comments in following scripts: 2 places in mysql/configmap.yaml, 2 places in openemr/deployment.yaml, 1 place in phpmyadmin/configmap.yaml, 1 place in phpmyadmin/deployment.yaml).
  - Redis - Configured to support failover. There is 1 master and 2 slaves (no read access on slaves) for a statefulset, 3 sentinels for another statefulset, and then 2 proxies deployment. The proxies ensure that redis traffic is always directed towards master. The proxy replications can be increased/decreased. However the primary/slaves and sentinels would require script changes if wish to increase/decrease replicates for these since these are hard-coded several place in the scripts. There are 3 users/passwords (`default` (defaultpassword), `replication` (replicationpassword), `admin` (adminpassword)) used in this redis scheme, and the passwords should be set to something else if use this scheme in production. The main place the passwords are set is in kubernetes/redis/configmap-acl.yaml script. Other places where passwords are used include the following: `replication` in kubernetes/redis/configmap-main.yaml, `admin` in kubernetes/redis/configmap-pipy.yaml, `admin` in kubernetes/redis/statefulset-sentinel.yaml. The `default` is the typical worker/app/client user.
  - phpMyAdmin - There is 1 deployment instance of phpMyAdmin. Ports for both http and https.

Would not consider this production quality, but will be a good working, starting point, and hopefully open the door to a myriad of other kubernetes based solutions. Note this is supported by 7.0.0 and higher dockers. If wish to use the most recent development codebase, then can change from openemr/openemr:7.0.2 to openemr/openemr:dev (in the openemr/deployment.yaml script), which is built nightly from the development codebase. If you wish to build dynamically from a branch/tag from a github repo or other git repo, then can change from openemr/openemr:7.0.2 to openemr/openemr:flex (in the openemr/deployment.yaml script) (note this will take much longer to start up (probably at least 10 minutes and up to 90 minutes) and is more cpu intensive since each instance of OpenEMR will download codebase and build separately).

# Use
1. Install (and then start) Kubernetes with Minikube or Kind or other.
    - For Minikube or other, can find online documentation.
    - For Kind, see below for instructions sets with 1 node or 4 nodes.
        - 1 node:
            ```bash
            kind create cluster
            kubectl cluster-info --context kind-kind
            ```
        - 4 nodes (1 control-plane node and 3 worker nodes), which will store shared volumes in host at /tmp/hostpath-provisioner to allow nodes to share volumes (you will need to remove the contents of the /tmp/hostpath-provisioner when tearing this down to prevent the shared volumes causing issues when rebuild it):
            ```bash
            kind create cluster --config kind-config-4-nodes.yaml
            kubectl cluster-info --context kind-kind
            ```
            - Use following command to ensure all the nodes are ready before proceeding to next step
                ```bash
                kubectl get nodes
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
          NAME                              READY   STATUS    RESTARTS   AGE
          pod/mysql-sts-0                   1/1     Running   0          111s
          pod/mysql-sts-1                   1/1     Running   0          91s
          pod/openemr-7889cf48d8-9jdfl      1/1     Running   0          111s
          pod/openemr-7889cf48d8-qphrw      1/1     Running   0          111s
          pod/openemr-7889cf48d8-zlx9f      1/1     Running   0          111s
          pod/phpmyadmin-f4d9bfc69-rx82d    1/1     Running   0          111s
          pod/redis-0                       1/1     Running   0          111s
          pod/redis-1                       1/1     Running   0          77s
          pod/redis-2                       1/1     Running   0          55s
          pod/redisproxy-744b7749dc-c6pkw   1/1     Running   0          111s
          pod/redisproxy-744b7749dc-k8rzp   1/1     Running   0          111s
          pod/sentinel-0                    1/1     Running   0          111s
          pod/sentinel-1                    1/1     Running   0          34s
          pod/sentinel-2                    1/1     Running   0          30s

          NAME                 TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                         AGE
          service/kubernetes   ClusterIP      10.96.0.1      <none>        443/TCP                         3m40s
          service/mysql        ClusterIP      None           <none>        3306/TCP                        111s
          service/openemr      LoadBalancer   10.96.6.51     <pending>     8080:32561/TCP,8090:32468/TCP   111s
          service/phpmyadmin   NodePort       10.96.64.163   <none>        8081:32195/TCP,8091:31981/TCP   111s
          service/redis        ClusterIP      None           <none>        6379/TCP                        111s
          service/redisproxy   ClusterIP      None           <none>        6379/TCP                        111s
          service/sentinel     ClusterIP      None           <none>        5000/TCP                        111s

          NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
          deployment.apps/openemr      3/3     3            3           111s
          deployment.apps/phpmyadmin   1/1     1            1           111s
          deployment.apps/redisproxy   2/2     2            2           111s

          NAME                                    DESIRED   CURRENT   READY   AGE
          replicaset.apps/openemr-7889cf48d8      3         3         3       111s
          replicaset.apps/phpmyadmin-f4d9bfc69    1         1         1       111s
          replicaset.apps/redisproxy-744b7749dc   2         2         2       111s

          NAME                         READY   AGE
          statefulset.apps/mysql-sts   2/2     111s
          statefulset.apps/redis       3/3     111s
          statefulset.apps/sentinel    3/3     111s
          ```
4. Getting the url link to OpenEMR:
    - If using minikube, can get the link to go to OpenEMR with following command (use the top link for http and bottom link for https):
        ```bash
        minikube service openemr --url
        ```
        - It will look something like this:
            ```console
            http://192.168.99.100:31314
            http://192.168.99.100:30613
            ```
    - If using kind, then can use the 3***** port(s) (1st is http, 2nd is https) shown in step 3 (at `service/openemr`) above with the ip address obtained from following command:
        ```bash
        docker inspect kind-control-plane | grep "IPAddress"
        ```
5. Getting the url link to phpMyAdmin:
    - If using minikube, can get the link to go to phpMyAdmin with following command:
        ```bash
        minikube service phpmyadmin --url
        ```
        - It will look something like this:
            ```console
            http://192.168.99.100:30571
            http://192.168.99.100:30578
            ```
    - If using kind, then can use the 3***** port(s) (1st is http, 2nd is https) shown in step 3 (at `service/phpmyadmin`) above with the ip address obtained from following command:
        ```bash
        docker inspect kind-control-plane | grep "IPAddress"
        ```
6. Some cool replicas stuff with OpenEMR. The OpenEMR docker pods are run as a replica set (since it is set to 3 replicas in this OpenEMR deployment script). Gonna cover how to view the replica set and how to change the number of replicas on the fly in this step.
    - First. lets list the replica set like this:
        ```bash
        kubectl get rs
        ```
        - It will look something like this (note OpenEMR has 3 desired and 3 current replicas going):
            ```console
            NAME                    DESIRED   CURRENT   READY   AGE
            openemr-7889cf48d8      3         3         3       9m22s
            phpmyadmin-f4d9bfc69    1         1         1       9m22s
            redisproxy-744b7749dc   2         2         2       9m22s
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
8. To stop and remove OpenEMR orchestration (this will delete everything):
    ```bash
    bash kub-down
    ```
    - For Kind, also need to delete the cluster:
        ````bash
        kind delete cluster
        ````
    - Additionally, if using Kind with 4 nodes, then also need to delete the shared volume at /tmp/hostpath-provisioner
        ````bash
        sudo rm -fr /tmp/hostpath-provisioner
        ````
