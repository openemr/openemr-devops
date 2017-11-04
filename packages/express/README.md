# OpenEMR Cloud Express

This process will install a fully-functional, secured, preconfigured OpenEMR 5.0.0 instance on your Ubuntu server, providing an embedded MySQL server and rotated, automatic backups of all OpenEMR configuration and health information. While AWS is the main target, there is documentation around deploying on-premise as well.

## Installation

1. From the AWS EC2 Dashboard, select *Launch Instance*.
2. Select *AWS Marketplace*, search for `OpenEMR Express`, then *Select* it.
3. Select *Continue*.
4. Select a suitable instance type (we recommend a minimum `t2.small`), then *Next: Configure Instance Details*.
5. Specify how you'd like the instance connected to Amazon's network and the internet, then select *Next: Add Storage*.
   * Your default VPC will probably be fine. *Auto-Assign Public IP* should be `Enable`.
6. Create a root instance with enough room to hold your projected patient files, minimum *8* GB, and then select *Next: Add Tags*.
7. Assuming you don't have any tags to add here, proceed to *Next: Configure Security Group*.
8. Select `Select an existing security group` to accept the default OpenEMR security settings, which you can customize.
   * You probably don't want SSH open to the world &mdash; you could tighten it to just your own IP, or just your office, right now.
9. Select *Review and Launch*, then *Launch*, then *View Instances*.
   * A message box concerning keypairs may show up, simply follow the prompts.
10. Click the instance in EC2 that's currently being created. Note the *IPv4 Public IP* and *Instance ID* entries.
11. Your OpenEMR installation is being constructed! In a few minutes, you can log in.
    * URL: `http://your-public-ip`
    * Username: `admin`
    * Password: `your-instance-id` (this will start with 'i-')

## Administration

### General

* The instance should be answering on port 80 inside of ten minutes. If it's not...
  * `tail -f /tmp/launch.log` to see if it's still running, or where it got stuck.
  * Transient build failures are possible if container dependencies are temporarily unavailable, just retry.
  * You will need network access, don't try to build from a private IP without NAT egress.
  * Check the process list, make sure `auto_configure.php` isn't running before you attempt to log in.
* Need access to the containers? Log into root, and...
  * Apache: `docker exec -it $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh`
  * MySQL: `docker exec -it $(docker ps | grep mysql | cut -f 1 -d " ") /bin/bash`
* Visit container volume: `docker volume ls`, `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`

### HIPAA Compliance

Although Amazon EC2 is a [HIPAA Eligible Service](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/), the Marketplace-supplied instance of OpenEMR Cloud Express does not meet some parts of the HIPAA Security Rule. HIPAA Covered Entities may not store Protected Health Information on this product, and should confine their use of OpenEMR Cloud Express to demonstration or training use only.

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

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and it is encouraged that you explore them as soon as possible.

## Support

The OpenEMR [forums](https://community.open-emr.org/) and [chat](https://chat.open-emr.org/) are available if you have any questions. We'll be happy to help!
