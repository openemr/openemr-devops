# OpenEMR Env Installer Documentation

## Overview

OpenEMR Env Installer is used to set up the base and necessary services(e.g. git, docker, docker-compose, openemr-cmd, minikube and kubectl) easily for the development/testing environment. You can save time to set up the base services especially you need multiple environments in different machines. OpenEMR Env Installer is available on ubuntu, debian, centos, rhel, fedora and macOS.

## Implementation

1. Download the env installer to your local dev/test environment, e.g.

```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-env-installer/openemr-env-installer > openemr-env-installer
```

2. Apply executable permissions to the script. 

```
chmod +x openemr-env-installer
```

3. Test the installation.

```
# ./openemr-env-installer
Usage: bash openemr-env-installer <code location> <github account>

  e.g. bash openemr-env-installer /home/test/code testuser
    or bash openemr-env-installer /Users/test/code testuser

NOTE1: Please make sure you have created your own fork of OpenEMR and OpenEMR-devops at first.
NOTE2: Please make sure you have the necessary environment if use minikube:
       * 2 CPUs or more
       * 2GB of free memory
       * 20GB of free disk space
       * Internet connection
       * Container or virtual machine manager,
         such as: Docker, Hyperkit, Hyper-V, KVM, Parallels, Podman, VirtualBox, or VMWare
```
