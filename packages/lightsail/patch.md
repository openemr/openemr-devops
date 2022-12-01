# OpenEMR Container-Based Patch

## Requirements

 * OpenEMR 5.0.0 or later, installed or launched via `docker-compose`. (Did you get here through the AWS Marketplace? You're in the right place.)
 * Up-to-the-minute backups. Full-instance volume snapshots, Duplicity backups, and (if appropriate) an [RDS snapshot](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateSnapshot.html) are the minimum acceptable.
 * Familiarity with how to restore those backups &mdash; do you know how to get your backups running on a clean OpenEMR instance? There is literally no better time to learn than right now, before you proceed.

## Overview

To patch OpenEMR, you'll want to follow four steps:
 * Backup your system.
 * If needed, ssh into your instance and get to a root shell with `sudo bash`.
 * Create script and install the schema patch templates.
 * Run the patch script. If you're running multi-site you'll follow a different procedure detailed below.
 * Delete the patch templates and run a fresh backup.

## Procedure

We detail here the steps involved in the `7.0.0` patch 1 process. For more recent patches you'll have to change the url of the patch.zip file in Step Two.

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
#docker exec -it "$OE_INSTANCE" sh -c 'curl -L https://raw.githubusercontent.com/openemr/openemr/v7_0_0_2/admin.php > /var/www/localhost/htdocs/openemr/admin.php'
docker exec -it "$OE_INSTANCE" sh -c 'curl -L https://raw.githubusercontent.com/openemr/openemr/v7_0_0_2/sql_patch.php > /var/www/localhost/htdocs/openemr/sql_patch.php'
docker exec -it "$OE_INSTANCE" sh -c 'curl -L https://www.open-emr.org/patch/7-0-0-Patch-2.zip > /var/www/localhost/htdocs/openemr/7-0-0-Patch-2.zip'
#docker exec "$OE_INSTANCE" chown apache:root /var/www/localhost/htdocs/openemr/admin.php 
docker exec "$OE_INSTANCE" chown apache:root /var/www/localhost/htdocs/openemr/7-0-0-Patch-2.zip /var/www/localhost/htdocs/openemr/sql_patch.php
#docker exec "$OE_INSTANCE" chmod 400 /var/www/localhost/htdocs/openemr/admin.php 
docker exec "$OE_INSTANCE" chmod 400 /var/www/localhost/htdocs/openemr/7-0-0-Patch-2.zip /var/www/localhost/htdocs/openemr/sql_patch.php
docker exec "$OE_INSTANCE" unzip -o /var/www/localhost/htdocs/openemr/7-0-0-Patch-2.zip
```

You can copy and paste the above and create a patch.sh script. Paste above text into vi after typing `vi patch.sh` and then `i` to enter vi insert mode, then save with `:wq` . Then make it executable and run the patch script
to copy the files into the OpenEMR docker.
```
chmod +x patch.sh
./patch.sh
```

### Step Three - Run the templates
For one site navigate to `http://<your-instance>/sql_patch.php` and select `Patch database`.
For multisite go to `http://<server_name>/openemr/admin.php` and select `Patch database` for each site.

That's it. You've patched OpenEMR! 

### Step Four - Backup and clean up

If you're using OpenEMR Standard, go ahead and make a post-upgrade RDS snapshot.

Create a cleanup script to delete sensitive scripts.
```
#!/bin/sh

# make a restore-point
/etc/cron.daily/duplicity-backups

#delete upgrade files that have served their purpose
OE_INSTANCE=$(docker ps | grep _openemr | cut -f 1 -d " ")
docker exec "$OE_INSTANCE" rm -f /var/www/localhost/htdocs/openemr/admin.php /var/www/localhost/htdocs/openemr/sql_patch.php /var/www/localhost/htdocs/openemr/7-0-0-Patch-2.zip

# comment below line to avoid deleting the patch script created above
rm ./patch.sh 
```

 Copy the above text and use vi like before with the patch.sh script. Here we do it with `vi clean-up.sh`. Then make the script executable and run.
```
chmod +x clean-up.sh
./clean-up.sh
```

If there are any issues please contact https://community.open-emr.org/  