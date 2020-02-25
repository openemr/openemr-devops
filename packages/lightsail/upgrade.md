# OpenEMR Container-Based Upgrade

## Requirements

 * OpenEMR 5.0.0 or later, installed or launched via `docker-compose`. (Did you get here through the AWS Marketplace? You're in the right place.)
 * Up-to-the-minute backups. Full-instance volume snapshots, Duplicity backups, and (if appropriate) an RDS snapshot are the minimum acceptable.
 * Familiarity with how to restore those backups &mdash; do you know how to get your backups running on a clean OpenEMR instance? There is literally no better time to learn than right now, before you proceed.


## Upgrading from 5.0.1 to 5.0.2+

### Overview

To upgrade OpenEMR, you'll want to follow one step:
 * Backup your system and upgrade your local container.

### Procedure

We detail here the steps involved in the `5.0.1` to `5.0.2+` upgrade process.

Note that if literally the only thing you're using is an OpenEMR docker, and not a Lightsail launch or an AWS Marketplace solution, then this document outlines the general step to take, but refers to scripts and directories you haven't created, so you'll need to treat this as a recipe and season it yourself.

#### Step One

(Are you using OpenEMR Standard? Don't forget to make an RDS snapshot as well as running the Duplicity backup.)

```
#!/bin/sh

# make a restore-point
/etc/cron.daily/duplicity-backups

# pull in 5.0.2 container
cd /root/openemr-devops/packages/lightsail
sed -i 's/5.0.1/5.0.2/' docker-compose.yml
./docker-compose up -d
```


## Upgrading from 5.0.0 to 5.0.1

### Overview

To upgrade OpenEMR, you'll want to follow four steps:
 * Backup your system and upgrade your local container.
 * Install the schema upgrade templates.
 * Run the upgrade script.
 * Delete the upgrade templates.

### Procedure

We detail here the steps involved in the `5.0.0` to `5.0.1` upgrade process. Docker-based installation is new to the 5.0 series, so this document won't be able to help you with upgrades from 4.x, and upgrades to future versions will require slightly divergent scripts. You may either copy these scripts directly, or paste them line by line into a (root) console.

Note that if literally the only thing you're using is an OpenEMR docker, and not a Lightsail launch or an AWS Marketplace solution, then this document outlines the general steps to take, but refers to scripts and directories you haven't created, so you'll need to treat this as a recipe and season it yourself.

#### Step One

(Are you using OpenEMR Standard? Don't forget to make an RDS snapshot as well as running the Duplicity backup.)

```
#!/bin/sh

# make a restore-point
/etc/cron.daily/duplicity-backups

# pull in 5.0.1 container
cd /root/openemr-devops/packages/lightsail
sed -i 's/5.0.0/5.0.1/' docker-compose.yml
./docker-compose up -d
```

#### Step Two

```
#!/bin/sh

# retrieve files deleted for security
OE_INSTANCE=$(docker ps | grep _openemr | cut -f 1 -d " ")
docker exec -it $OE_INSTANCE sh -c 'curl -L https://raw.githubusercontent.com/openemr/openemr/v5_0_1/sql_upgrade.php > /var/www/localhost/htdocs/openemr/sql_upgrade.php'
docker exec -it $OE_INSTANCE sh -c 'curl -L https://raw.githubusercontent.com/openemr/openemr/v5_0_1/acl_upgrade.php > /var/www/localhost/htdocs/openemr/acl_upgrade.php'
docker exec $OE_INSTANCE chown apache:root /var/www/localhost/htdocs/openemr/sql_upgrade.php /var/www/localhost/htdocs/openemr/acl_upgrade.php
docker exec $OE_INSTANCE chmod 400 /var/www/localhost/htdocs/openemr/sql_upgrade.php /var/www/localhost/htdocs/openemr/acl_upgrade.php
```

#### Step Three

Navigate to `http://<your-instance>/sql_upgrade.php` and select `5.0.0`.

#### Step Four

(If you're using OpenEMR Standard, go ahead and make a post-upgrade RDS snapshot.)

```
#!/bin/sh

# make a restore-point
/etc/cron.daily/duplicity-backups

#delete upgrade files that have served their purpose
OE_INSTANCE=$(docker ps | grep _openemr | cut -f 1 -d " ")
docker exec $OE_INSTANCE rm -f /var/www/localhost/htdocs/openemr/sql_upgrade.php /var/www/localhost/htdocs/openemr/acl_upgrade.php
```
