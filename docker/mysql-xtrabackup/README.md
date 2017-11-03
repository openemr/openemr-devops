# mysql-xtrabackup

## Overview

This is a modified version of the official MySQL 5.7 Docker, largely stock but also pulling in Percona XtraBackup and various shell scripts. Automation has been provided to allow the host to run hot MySQL backups, and considerable assistance has been provided to allow selection and recovery from these backups.

## Installation

The [official Docker](https://hub.docker.com/_/mysql/) should be consulted for installation and configuration notes.

## XtraBackup Operation

### Backups

 * Run a hot database backup: `docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xbackup-wrapper.sh`
 * `xbackup-wrapper.sh` will run a full backup once a week, and an incremental on other days.
 * Backups will be placed in `/mnt/backups` and rotated to guarantee two fresh full backups are available at any time.

### Recovery

  * Do you need to copy the backup files into the instance? `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")` to visit the volume on the host.
  * Call `/root/xrecovery.sh` by itself or with a specific backup's `-info.log` file.
    * `-m <memory_pool>` will set XtraBackup's allowed allocation, given as `750M` or `2.5G`.
  * `xrecovery.sh` will determine if it's loading a full or incremental backup, construct a chain of incrementals to backtrack to a full backup if required, apply all required backups, and restart the docker to complete the alterations to the local MySQL datadir.

#### Low Memory Users

If the backup process fails citing problems with open files, and you have less than a gigabyte of memory in total, try launching `xrecovery.sh` with an `-m` option like `125M` or even `25M`.

### Administration

  * Add the backup command to an after-hours crontab on the host.
  * Share the `/mnt/backups` volume and have your host back up that target and transport it off-site.
  * The restore process is completely destructive. If it goes badly wrong and surgery is required, the pre-recovery datadir is available at `/mnt/backups/prerecovery-mysql-datadir`.
  * This is a very complex problem, and XtraBackup is not simple. You are encouraged to test the recovery process with production data on a test instance *before* the world ends.

## Known Issues

 * `innobackup.cnf` hardcodes the local MySQL root password as 'root', but the initial config should be setting this.
