# OpenEMR Cloud Launchpad

OpenEMR Cloud Launchpad on the Google Cloud Platform provides OpenEMR 5.0.2, an embedded MySQL server, and rotated, automatic backups of all OpenEMR configuration and health information.

## Installation

### Requirements

A Google Cloud account in good standing.

### Directions

Follow our [Getting Started Guide](https://www.open-emr.org/wiki/index.php/Google_Launchpad) to provision and log in to [OpenEMR Launchpad](https://console.cloud.google.com/launcher/details/oemr-public/openemr-launchpad).

## Administration

### General

* Need access to the containers? Connect to user `ubuntu`, sudo to root, and...
  * Apache: `docker exec -it $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh`
  * MySQL: `docker exec -it $(docker ps | grep mysql | cut -f 1 -d " ") /bin/bash`
* Visit container volume: `docker volume ls`, `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`

#### Set Local Timezone

1. See http://php.net/manual/en/timezones.php for the PHP timezone for your region.
2. `sudo bash`
3. `docker exec $(docker ps | grep _openemr | cut -f 1 -d " ") sed -i 's^;date.timezone\ =^date.timezone = <your timezone>^' /etc/php7/php.ini`
4. `docker restart $(docker ps | grep _openemr | cut -f 1 -d " ")`

### HIPAA Compliance

Todo...

### Backups

Duplicity is installed to the host machine to manage and rotate backups. It can be configured to send the backups it creates to off-instance storage, but currently does not attempt to do so. `/etc/cron.daily/duplicity-backups` holds the daily backup process that snapshots both the MySQL database, the OpenEMR configuration, and any patient documents that have been created, storing them in `/root/backups`.

Full backups are made every seven days, with incrementals for the other days. The Duplicity backups encompass the MySQL database backups.

#### Recovering from Backup

It is recommended, in the strongest possible terms, that you familiarize yourself with the recovery process as soon as possible. Launch a backup process, move the created backup files to a fresh instance, and try to recover them &mdash; this test, performed regularly, ensures smooth recovery in the face of catastrophe.

1. If necessary, place the compressed backup archive bundle in `/root/backups`.
2. As root, launch `/root/restore.sh`, and carefully read the warning it supplies you.
3. Take the actions it suggests &mdash; make an image snapshot if possible &mdash; and then, once ready, edit the script as instructed and run it anew.
4. Duplicity will unpack the MySQL backups it's holding, the OpenEMR configuration directory, and any patient documents that have been saved.
5. XtraBackup will launch, applying the most recent full backup and all the daily incrementals.
6. The MySQL container will be restarted to pick up the newly constructed data directory, and at this point your backups should be completely restored.

See the `mysql-xtrabackup` container for more information about the `xbackup.sh` and `xrecovery.sh` scripts called by the Duplicity wrappers.

#### Backup Cross-Compatibility

OpenEMR Cloud Launchpad backup files are cross-compatible with the [Express](../express), [Appliance](../appliance) and [Ubuntu Installer](../lightsail) deployment packages; you should be able to migrate your practice between any of the four if you move the backups onto the target.

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and it is encouraged that you explore them as soon as possible.

## Support

The OpenEMR [forums](https://community.open-emr.org/) and [chat](https://chat.open-emr.org/) are available if you have any questions. We'll be happy to help!
