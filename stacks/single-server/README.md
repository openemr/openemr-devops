# OpenEMR Cloud Express

This process will install a fully-functional, secured, preconfigured OpenEMR 5.0.0 instance on your Ubuntu server, providing an embedded MySQL server and providing rotated, automatic backups of all OpenEMR configuration and patient health information.

## Requirements

* Ubuntu 16.04 server (root access, 512 MB RAM, 20 GB storage)
* Outbound internet access (during installation)

## Installation

### AWS Lightsail

1. Click *Create Instance*.
2. Consider changing your region, or accept the datacenter Amazon has selected.
3. For *Instance Image*, select *OS Only*, then *Ubuntu 16.04 LTS*.
4. Click the *+* to add a launch script, then paste the following.
```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/stacks/single-server/launch.sh > ./lightsail-launch.sh
chmod +x ./lightsail-launch.sh && sudo ./lightsail-launch.sh
```
5. Select an instance size that meets your budget.
6. Name your instance and click *Create*.
7. The instance will shortly be visible as `Pending`, and then `Active`.
8. You can connect to the instance (see below) and monitor the logs, or you can let it bake for perhaps ten minutes. Either way, once installation has completed, browse to the IP shown in Lightsail and log in to OpenEMR.
   * Login: `admin`
   * Password: `pass`
   * After login, under `Administration` and `Users`, you'll find the `admin` user and a chance to change that password.
9. OpenEMR is now ready for use!

#### Lightsail SSH Keys

Lightsail has its own SSH key manager, independent of EC2. You may create or upload a key you'd like Lightsail to use, or you can elect to use the Lightsail default key AWS assigns your account. If you don't download the key, you can still use the Lightsail-supplied browser client to securely connect to your instance. Click the icon of a monitor with a shell cursor to do so.

#### Lightsail DNS, Static IP, Networking

Lightsail has the ability to assign static IPs to instances, and the ability to manage domains and subdomains to direct traffic to them, but a tutorial on their use is beyond the scope of this guide. The `Manage`, `Networking` options will allow you to control the ports available to the instance, perhaps turning SSH off when not in use (by you) for added security, or turning SSL on if a domain certificate is installed to the Apache container.

#### Lightsail Snapshots

You can stop your OpenEMR instance to take a full copy of it, and then restart it; the snapshot copy will persist, and can be independently started as a separate instance, allowing you to create ad-hoc backups or test beds for OS upgrades, OpenEMR security patches, or to try out procedures like the recovery process before you use them in production.

### Non-Lightsail Installation

Although the script is called `lightsail-launch.sh`, nothing in it is AWS Lightsail-specific; download and run the script as root to install the two Docker containers, `openemr` and `mysql-xtrabackup`, that represent the application. If you have more than a gigabyte of memory, or you are specifically billed for I/O activity, you may wish to consider editing the script before launch and removing the swap-allocating functionality.

## Administration

* The instance should be answering on port 80 inside of ten minutes. If it's not...
  * `tail -f /tmp/lightsail-launch.log` to see if it's still running, or where it got stuck
  * Transient build failures are possible if container dependencies are temporarily unavailable, just retry
  * You will need network access, don't try to build from a private IP without NAT egress
  * Check the process list, make sure `auto_configure.php` isn't running before you attempt to log in.
* Need access to the containers? Log into root, and...
  * Apache: `docker exec $(docker ps | grep openemr | cut -f 1 -d " ") /bin/sh`
  * MySQL: `docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /bin/bash`
* Visit container volume: `docker volume ls`, `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`

### HIPAA Compliance

As of September 2017, AWS Lightsail is not a [HIPAA Eligible Service](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/). HIPAA Covered Entities may not store Protected Health Information on AWS Lightsail, and should confine their use of OpenEMR Cloud Express to demonstration or training use only. (Use of the software on other servers may be possible and should be discussed with your compliance officer.)

## Backups

Duplicity is installed to the host machine to manage and rotate backups. It can be configured to send the backups it creates to off-instance storage, but currently does not attempt to do so. `/etc/cron.daily/duplicity-backup` holds the daily backup process that snapshots both the MySQL database, the OpenEMR configuration, and any patient documents that have been created, storing them in `/root/backups`.

Full backups are made every seven days, with incrementals for the other days. The Duplicity backups encompass the MySQL database backups.

### Recovering From Backup

It is recommended, in the strongest possible terms, that you familiarize yourself with the recovery process as soon as possible. Launch a backup process, move the created backup files to a fresh instance, and try to recover them &mdash; this test, performed regularly, ensures smooth recovery in the face of catastrophe.

1. If necessary, place the compressed backup archive bundle in `/root/backups`.
2. As root, launch `/root/duplicity-restore.sh`, and carefully read the warning it supplies you.
3. Take the actions it suggests &mdash; make an image snapshot if possible &mdash; and then, once ready, edit the script as instructed and run it anew.
4. Duplicity will unpack the MySQL backups it's holding, the OpenEMR configuration directory, and any patient documents that have been saved.
5. XtraBackup will launch, applying the most recent full backup and all the daily incrementals.
6. The MySQL container will be restarted to pick up the newly constructed data directory, and at this point your backups should be completely restored.

See the `mysql-xtrabackup` container for more information about the `xbackup.sh` and `xrecovery.sh` scripts called by the Duplicity wrappers.

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and I encourage you to explore them as soon as possible.

## Developer Notes

### launch.sh Command-Line Parameters

* *-b* &lt;branch-name&gt;: load specific branch of openemr-devops repository
* *-s* &lt;swap-size-GB&gt;: amount of swap to allocate for small instances; 0 for none
* *-d*: use the developer docker-compose file
  * use `build` directive instead of `image` to run repository containers instead of hub
  * force MySQL port world-readable

## Support

The OpenEMR [forums](https://community.open-emr.org/) and [chat](https://chat.open-emr.org/) are available if you have any questions. We'll be happy to help!
