[![ShellCheck](https://github.com/openemr/openemr-devops/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/openemr/openemr-devops/actions/workflows/shellcheck.yml)
[![Docker Compose Linting](https://github.com/openemr/openemr-devops/actions/workflows/dclint.yml/badge.svg)](https://github.com/openemr/openemr-devops/actions/workflows/dclint.yml)

# openemr-devops

OpenEMR administration and deployment tooling

## Resource Index

### Deployment Options

* [Ubuntu Installer](packages/appliance): Launch OpenEMR on any Ubuntu 24.04 instance
* [Kubernetes](kubernetes): OpenEMR Kubernetes orchestration. Working starting point with mTLS, Redis Sentinel failover, multi-node support; also serves as a reference for secure distributed deployments
* [Raspberry Pi](raspberrypi): Install OpenEMR Docker on Raspberry Pi (supports ARMv8 infrastructure)

### Installations for Amazon Web Services

* [OpenEMR Cloud Standard](packages/standard): OpenEMR webserver and separate, managed database instance
* [OpenEMR Cloud Express](packages/express): AWS Marketplace-supplied preconfigured OpenEMR instance
* [OpenEMR Cloud Express Plus](packages/express_plus): Self-contained OpenEMR instance with more complex features
* [OpenEMR on ECS](https://github.com/openemr/openemr-on-ecs): Serverless, scaling OpenEMR, built in CDK and managed by AWS Elastic Container Service
* [OpenEMR on EKS](https://github.com/openemr/openemr-on-eks): OpenEMR on AWS Elastic Kubernetes Service, delievered through Terraform  

See our [product comparison](https://www.open-emr.org/wiki/index.php/AWS_Cloud_Packages_Comparison) for more information on the costs and features of each offering.

### Management Utilities

* [OpenEMR Cmd](utilities/openemr-cmd): OpenEMR-Cmd is similar to devtools, it helps developers to manage and troubleshoot openemr outside the docker
* [OpenEMR Doctor](utilities/openemr-doctor): OpenEMR Doctor names why an install shows a blank page, an error 500 or a broken login, and what to do about it; it only reads, and runs on a Docker install with one `curl ... | bash` line
* [OpenEMR Env Installer](utilities/openemr-env-installer): OpenEMR Env Installer is used to set up the base and necessary services(e.g. git, docker, docker-compose, openemr-cmd, minikube, and kubectl) easily for the development/testing environment
* [OpenEMR Monitor](utilities/openemr-monitor): OpenEMR Monitor is based on Prometheus, cAdvisor, Grafana, and alertmanger which helps administrator to monitor the status of containers
* [Portainer](utilities/portainer): Portainer is a lightweight management UI which allows you to easily manage your different Docker environments (Docker hosts)
* [OpenEMR Environment Migrator](utilities/openemr-env-migrator): OpenEMR Environment Migrator is used to migrate your container environment to the new storage directory or the remote host easily

## Contact Us
The OpenEMR [Forum](https://community.open-emr.org/) and Slack are always available if you have any questions.
