# openemr-devops
OpenEMR administration and deployment tooling

## Resource Index

### Installations for Amazon Web Services

* [OpenEMR Cloud Standard](packages/standard): OpenEMR webserver and separate, managed database instance
* [OpenEMR Cloud Express](packages/express): AWS Marketplace-supplied preconfigured OpenEMR instance
* [OpenEMR Cloud Express Plus](packages/express_plus): Self-contained OpenEMR instance with more complex features
* [OpenEMR Cloud Full Stack](packages/full_stack): Multi-node CloudFormation OpenEMR cluster with tight AWS integration

See our [product comparison](https://www.open-emr.org/wiki/index.php/AWS_Cloud_Packages_Comparison) for more information on the costs and features of each offering. 

### Other Hosting

* [Ubuntu Installer](packages/lightsail): Launch OpenEMR on any Ubuntu 16.04 instance; examples given for AWS Lightsail hosting
* [Virtual Appliance](packages/appliance): Downloadable virtual appliance encapsulating a full OpenEMR install
* [Raspberry Pi](raspberrypi): Install OpenEMR Docker on Raspberry Pi (supports ARMv8 infrastructure)

### Components and Infrastructure

* [Official OpenEMR Docker](docker/openemr): Source repository for the [Docker](https://hub.docker.com/r/openemr/openemr/) library
* [mysql-xtrabackup Docker](docker/mysql-xtrabackup): MySQL 5.7 / Percona XtraBackup Docker container  

### Management Utilities

* [OpenEMR Cmd](utilities/openemr-cmd): OpenEMR-Cmd is similar to devtools, it helps developers to manage and troubleshoot openemr outside the docker
* [OpenEMR Env Installer](utilities/openemr-env-installer): OpenEMR Env Installer is used to set up the base and necessary services(e.g. git, docker, docker-compose, openemr-cmd, minikube, and kubectl) easily for the development/testing environment
* [OpenEMR Monitor](utilities/openemr-monitor): OpenEMR Monitor is based on Prometheus, cAdvisor, Grafana, and alertmanger which helps administrator to monitor the status of containers
* [Portainer](utilities/portainer): Portainer is a lightweight management UI which allows you to easily manage your different Docker environments (Docker hosts)
* [OpenEMR Environment Migrator](utilities/openemr-env-migrator): OpenEMR Environment Migrator is used to migrate your container environment to the new storage directory or the remote host easily
* [OpenEMR Kubernetes Orchestrations](kubernetes):  OpenEMR Kubernetes orchestration on Minikube. Creates 2 instances of OpenEMR with 1 instance of MariaDB, Redis, and phpMyAdmin.

### Community Contributions

 * [AWS Fargate](https://github.com/aws-samples/host-openemr-on-aws-fargate): Serverless OpenEMR deployment to AWS Fargate with the Amazon CDK.

## Contact Us
The OpenEMR [Forum](https://community.open-emr.org/) and Slack are always available if you have any questions.
