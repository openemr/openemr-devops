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

```
# ./openemr-env-migrator
Migrate all the containers:
  Scenario one: Please provide the <source dir> and <target dir> if migrate in local.
   e.g. openemr-env-migrator -l /var/lib/docker/ /data/docker/
  Scenario two: Please provide the <source dir>, <target ssh user>, <target ip> and <target dir> if migrate to remote host.
   First step in local:    openemr-env-migrator -m /var/lib/docker/ testuser 192.168.117.117 /data/docker/
   Second step in remote:  openemr-env-migrator -r /data/docker/
  **NOTE-1**: Do not forget the last slash of source dir, e.g. /var/lib/docker/
  **NOTE-2**: Please make sure there is the same source code dir in the remote host for easy or insane env and setup the base container services.

Migrate the single container:
  Please provide the <migrate container name>, <new container name>, <target ssh user> and <target ip>.
   e.g. openemr-env-migrator -s brave_snyder http testuser 192.168.117.117
```
