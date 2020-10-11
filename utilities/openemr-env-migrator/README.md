# OpenEMR Env Migrator Documentation

## Overview

Migrations are inevitable in many scenarios. Hardware upgrades, data center changes, obsolete OS, all these can be trigger points for migration. OpenEMR Env Migrator is used to migrate your container environment to the new dir or the remote host easily.

## Implementation

1. Download the env migrator to your local container environment, e.g.

```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-env-migrator/openemr-env-migrator > openemr-env-migrator
```

2. Apply executable permissions to the script. 

```
chmod +x openemr-env-migrator
```

3. Test the installation.
    - Please make sure rsync already set up in local host if the local migration,  make sure rsync and ssh already set up in both hosts if the remote migration.
```
# ./openemr-env-migrator
Usage:
    -t,      Specify the migration type e.g. local, remote, set, single.
    -s,      Specify the migration container source directory.
    -d,      Specify the migration container target directory.
    -u,      Specify the target host ssh user.
    -h,      Specify the target host ip.
    -m,      Specify the migration source container.
    -n,      Specify the migration new container name.

Migrate all the containers:
  Scenario one: Migrate in local.
   e.g. openemr-env-migrator -t local -s /var/lib/docker/ -d /data/docker/
  Scenario two: Migrate to remote host.
   First step in local:    openemr-env-migrator -t remote -s /var/lib/docker/ -u testuser -h 192.168.117.117 -d /data/docker/
   Second step in remote:  openemr-env-migrator -t set -d /data/docker/
  **NOTE-1**: Do not forget the last slash of source dir, e.g. /var/lib/docker/
  **NOTE-2**: Please make sure there is the same source code dir in the remote host for easy or insane env and setup the base container services.

Migrate the single container:
   e.g. openemr-env-migrator -t single -m  brave_snyder -n http -u testuser -h 192.168.117.117
```
