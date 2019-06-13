# OpenEMR Container-Based Patch

## Requirements

 * OpenEMR 5.0.0 or later, installed or launched via `docker-compose`. (Did you get here through the AWS Marketplace? You're in the right place.)
 * Up-to-the-minute backups. Full-instance volume snapshots, Duplicity backups, and (if appropriate) an RDS snapshot are the minimum acceptable.
 * Familiarity with how to restore those backups &mdash; do you know how to get your backups running on a clean OpenEMR instance? There is literally no better time to learn than right now, before you proceed.

## Overview

To patch OpenEMR, you'll want to follow four steps:
 * Backup your system.
 * Install the schema patch templates.
 * Run the patch script. If you're running multi-site you'll follow a different procedure detailed below.
 * Delete the patch templates.

## Procedure

We detail here the steps involved in the `5.0.1` patch 7 process. For more recent patches you'll have to change the url of the patch.zip file in Step Two.

You may either copy these scripts directly, or paste them line by line into a (root) console.

Note that if literally the only thing you're using is an OpenEMR docker, and not a Lightsail launch or an AWS Marketplace solution, then this document outlines the general steps to take, but refers to scripts and directories you haven't created, so you'll need to treat this as a recipe and season it yourself.

### Step One - Backup your system

(Are you using OpenEMR Standard? Don't forget to make an RDS snapshot as well as running the Duplicity backup.)

```
#!/bin/sh

# make a restore-point
/etc/cron.daily/duplicity-backups

```

### Step Two - Install the templates

Script to be run:
```
#!/bin/sh

# Retrieve files deleted for security and unzip into openemr directory.
# Note that you may be copying over your own custom files so BEWARE!
# For multi-site also uncomment the 3 commented docker exec lines below. 
 
OE_INSTANCE=$(docker ps | grep _openemr | cut -f 1 -d " ")
#docker exec -it $OE_INSTANCE sh -c 'curl -L https://raw.githubusercontent.com/openemr/openemr/v5_0_1/admin.php > /var/www/localhost/htdocs/openemr/admin.php'
docker exec -it $OE_INSTANCE sh -c 'curl -L https://raw.githubusercontent.com/openemr/openemr/v5_0_1/sql_patch.php > /var/www/localhost/htdocs/openemr/sql_patch.php'
docker exec -it $OE_INSTANCE sh -c 'curl -L https://www.open-emr.org/patch/5-0-1-Patch-7.zip > /var/www/localhost/htdocs/openemr/5-0-1-Patch-7.zip'
#docker exec $OE_INSTANCE chown apache:root /var/www/localhost/htdocs/openemr/admin.php 
docker exec $OE_INSTANCE chown apache:root /var/www/localhost/htdocs/openemr/5-0-1-Patch-7.zip /var/www/localhost/htdocs/openemr/sql_patch.php
#docker exec $OE_INSTANCE chmod 400 /var/www/localhost/htdocs/openemr/admin.php 
docker exec $OE_INSTANCE chmod 400 /var/www/localhost/htdocs/openemr/5-0-1-Patch-7.zip /var/www/localhost/htdocs/openemr/sql_patch.php
docker exec $OE_INSTANCE unzip -o /var/www/localhost/htdocs/openemr/5-0-1-Patch-7.zip
```

You can copy and paste the below script and make it executable for ease like patch.sh for example.
```
chmod +x patch.sh
./patch.sh
```

### Step Three - Run the templates

For one site navigate to `http://<your-instance>/sql_patch.php` and select `Patch database`.
For multisite go to `http://<server_name>/openemr/admin.php` and select `Patch database` for each site.

### Step Four - Backup and clean up

(If you're using OpenEMR Standard, go ahead and make a post-upgrade RDS snapshot.)

```
#!/bin/sh

# make a restore-point
/etc/cron.daily/duplicity-backups

#delete upgrade files that have served their purpose
OE_INSTANCE=$(docker ps | grep _openemr | cut -f 1 -d " ")
docker exec $OE_INSTANCE rm -f /var/www/localhost/htdocs/openemr/admin.php /var/www/localhost/htdocs/openemr/sql_patch.php /var/www/localhost/htdocs/openemr/5-0-1-Patch-7.zip

# uncomment to delete the patch script if created
# rm ./patch.sh 
```

That's it. You've patched OpenEMR! If there are any issues please contact https://community.open-emr.org/  