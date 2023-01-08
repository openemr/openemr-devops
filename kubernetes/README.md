# Overview
OpenEMR Kubernetes orchestration. Orchestration included OpenEMR, MariaDB, Redis, and phpMyAdmin.
    - OpenEMR - 3 deployment replications of OpenEMR are created.
    - MariaDB - 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created. Replications can be increased/decreased which will increase/decrease number of replica/slaves.
    - Redis - Configured to support failover. There is 1 master and 2 slaves (no read access on slaves) for a statefulset, 3 sentinels for another statefulset, and then 2 proxies deployment. The proxies ensure that redis traffic is always directed towards master. The proxy replications can be increased/decreased. However the primary/slaves and sentinels would require script changes if wish to increase/decrease replicates for these since these are hard-coded several place in the scripts. There are 3 users/passwords (`default` (nopass), `replication` (replicationpassword), `admin` (adminpassword)) used in this redis scheme, and the passwords should be set to something else if use this scheme in production. The main place the passwords are set is in kubernetes/redis/configmap-acl.yaml script. Other places where passwords are set include the following: `replication` in kubernetes/redis/configmap-main.yaml, `admin` in kubernetes/redis/configmap-pipy.yaml, `admin` in kubernetes/redis/statefulset-sentinel.yaml. The `default` is the typical worker/app/client user, which will plan to assign a password when OpenEMR docker is updated to support redis username/password.
    - phpMyAdmin - There is 1 deployment instance of phpMyAdmin.

Would not consider this production quality, but will be a good working, starting point, and hopefully open the door to a myriad of other kubernetes based solutions. Note this is supported by 6.0.0 and higher dockers. If wish to use the most recent development codebase, then can change from openemr/openemr:7.0.0 to openemr/openemr:flex in the openemr/deployment.yaml script (note this will take much longer to start up (probably at least 10 minutes and up to 90 minutes) and is more cpu intensive since each instance of OpenEMR will download codebase and build separately).

(Quick note: Development in progress, minikube or kind not required for deployment. :8080 for http, :8090 for https, grab the NodePort for phpmyadmin)

You should drop down to one OpenEMR instance-node before trying to pull in an updated image.

TODO (optimizing some things). Add support for redis password in the OpenEMR dockers; then add password to the default user in the redis acl (it is now set to work without a password); then turn on protected mode in redis config.

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
5. Getting the url link to OpenEMR:
    - If using minikube, can get the link to go to OpenEMR with following command (use the top link for http and bottom link for https):
        ```bash
        minikube service openemr --url
        ```
        - It will look something like this:
            ```console
            http://192.168.99.100:31314
            http://192.168.99.100:30613
            ```
    - If using kind, then can use the 3***** port shown in step 4 above with the ip address obtained from following command:
        ```bash
        docker inspect kind-control-plane | grep "IPAddress"
        ```
6. Getting the url link to phpMyAdmin:
    - If using minikube, can get the link to go to phpMyAdmin with following command:
        ```bash
        minikube service phpmyadmin --url
        ```
        - It will look something like this:
            ```console
            http://192.168.99.100:30571
            ```
    - If using kind, then can use the 3***** port shown in step 4 above with the ip address obtained from following command:
        ```bash
        docker inspect kind-control-plane | grep "IPAddress"
        ```
7. Some cool replicas stuff with OpenEMR. The OpenEMR docker pods are run as a replica set (since it is set to 3 replicas in this OpenEMR deployment script). Gonna cover how to view the replica set and how to change the number of replicas on the fly in this step.
    - First. lets list the replica set like this:
        ```bash
        kubectl get rs
        ```
        - It will look something like this (note OpenEMR has 3 desired and 3 current replicas going):
            ```console
            NAME                    DESIRED   CURRENT   READY   AGE
            mysql-64449b8cf7        1         1         1       4m5s
            openemr-5f6db6c87c      3         3         3       4m5s
            phpmyadmin-78968d6cfb   1         1         1       4m5s
            redis-74cc9d667         1         1         1       4m5s
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
8. Some cool replicas stuff with MariaDB. 2 statefulset replications of MariaDB (1 primary/master with 1 replica/slave) are created by default. The number of replicas can be increased or decreased.
    - Increase replicas (after this command will have the 1 primary/master with 3 replicas/slaves).
        ```bash
        kubectl scale sts mysql-sts --replicas=4
        ```
    - Decrease replicas (after this command will have the 1 primary/master with 2 replicas/slaves).
        ```bash
        kubectl scale sts mysql-sts --replicas=3
        ```
9. To stop and remove OpenEMR orchestration (this will delete everything):
    ```bash
    bash kub-down
    ```
