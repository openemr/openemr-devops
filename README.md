[![ShellCheck](https://github.com/openemr/openemr-devops/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/openemr/openemr-devops/actions/workflows/shellcheck.yml)
[![Docker Compose Linting](https://github.com/openemr/openemr-devops/actions/workflows/dclint.yml/badge.svg)](https://github.com/openemr/openemr-devops/actions/workflows/dclint.yml)

# openemr-devops

OpenEMR administration and deployment tooling

## Resource Index

### Components and Infrastructure

* [Official OpenEMR Docker](docker/openemr): Source repository for the [Docker](https://hub.docker.com/r/openemr/openemr/) library
  * **Production Docker Testing**: Automated workflow verifies production OpenEMR Docker images (versioned releases like 7.0.4) can build correctly and function with database connections. Tests include unit, fixtures, services, validators, and controllers suites.
  * **Flex Docker Testing**: Automated workflow tests development-oriented "flex" Docker images designed for development where OpenEMR code is mounted separately rather than embedded in the image.

### Deployment Options

* [Ubuntu Installer](packages/appliance): Launch OpenEMR on any Ubuntu 24.04 instance
* [Kubernetes](kubernetes): Two-worker OpenEMR Kubernetes orchestration on Minikube
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
* [OpenEMR Env Installer](utilities/openemr-env-installer): OpenEMR Env Installer is used to set up the base and necessary services(e.g. git, docker, docker-compose, openemr-cmd, minikube, and kubectl) easily for the development/testing environment
* [OpenEMR Monitor](utilities/openemr-monitor): OpenEMR Monitor is based on Prometheus, cAdvisor, Grafana, and alertmanger which helps administrator to monitor the status of containers
* [Portainer](utilities/portainer): Portainer is a lightweight management UI which allows you to easily manage your different Docker environments (Docker hosts)
* [OpenEMR Environment Migrator](utilities/openemr-env-migrator): OpenEMR Environment Migrator is used to migrate your container environment to the new storage directory or the remote host easily

## Contact Us
The OpenEMR [Forum](https://community.open-emr.org/) and Slack are always available if you have any questions.
