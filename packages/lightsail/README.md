# OpenEMR Cloud: Do-It-Yourself Lightsail Edition

This process will install a fully-functional, secured, preconfigured OpenEMR 7.0.0 instance on your Ubuntu server, providing an embedded MySQL server and rotated, automatic backups of all OpenEMR configuration and health information. While AWS is the main target, there is documentation around deploying to other webhosts or an on-premise server as well.

## Installation

### AWS Lightsail

1. From the AWS Lightsail Dashboard, click *Create Instance*.
2. Consider changing your region, or accept the datacenter Amazon has selected.
3. For *Instance Image*, select *OS Only*, then *Ubuntu 20.04 LTS*.
4. Click the *+* to add a launch script, then paste the following.
```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/lightsail/launch.sh > ./launch.sh
chmod +x ./launch.sh && sudo ./launch.sh
```
5. Select an instance size (minimum 'micro') that meets your budget.
6. Name your instance and click *Create*.
7. The instance will shortly be visible as `Pending`, and then `Active`.
8. Before you connect, select `...`, then `Manage`, then the `Networking` tab, and add the `HTTPS` port to the firewall pass-through.
9. You can connect to the instance (see below) and monitor the logs, or you can let it bake for perhaps ten minutes. Either way, once installation has completed, browse to the IP shown in Lightsail and log in to OpenEMR.
   * Login: `admin`
   * Password: `pass`
   * After login, under `Administration` and `Users`, you'll find the `admin` user and a chance to change that password.   
   * Optionally connect with https://&lt;your instance ip&gt;, using the temporary self-signed certificate. Accept the security exception for now.
10. OpenEMR is now ready for use!

### Custom Installation

#### Requirements

* Ubuntu 24.04 server (root access, 1 GB RAM, 20 GB storage)
* Outbound internet access (during installation)

#### Synopsis

Although built for AWS Lightsail and EC2 Marketplace, nothing in `launch.sh` is specific to that platform; on any Ubuntu 20.04 instance, you may download and run the script as root to install the two Docker containers, `openemr` and `mysql-xtrabackup`, that represent the application. If you have more than a gigabyte of memory, or you are specifically billed for I/O activity, you may wish to review the command-line parameters to disable the automatic allocation of swap space.

#### Directions

To install, run the same launch script, make sure you're provided inbound access to ports 22, 80 and 443, and largely follow the Lightsail directions as given.

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
* Run a quick backup? `/etc/cron.daily/duplicity-backups` as root.

#### Direct MySQL Access

You can open your container up for direct developer-grade database access.

```
cd /root/openemr-devops/packages/lightsail
# edit docker-compose.yml: expose port 3306 in the mysql container
./docker-compose up -d
mysql -h 127.0.0.1 -u root -p; # (password is root)
```
Note that many MySQL clients are hardwired to try to connect to a socket that the container will not expose, if you do not specify a host or specify `localhost`. If you need to access your instance remotely, you'll need to add a pinhole for 3306 to the security group &mdash; consider changing the MySQL access passwords (and updating OpenEMR's `sqlconf.php`) before proceeding.

#### Let's Encrypt SSL Certificates

After installation, if you've assigned your instance a domain, you may choose to use the onboard Let's Encrypt tooling to acquire an SSL certificate. Be warned: Because this procedure will rebuild your containers, your records may be at risk. It's recommended you employ it before production use.

```
cd /root/openemr-devops/packages/lightsail
# edit docker-compose.yml: add environment variables DOMAIN and EMAIL to the openemr container
./docker-compose up -d
```

### Lightsail Administration Notes

#### SSH Keys

Lightsail has its own SSH key manager, independent of EC2. You may create or upload a key you'd like Lightsail to use, or you can elect to use the Lightsail default key AWS assigns your account. If you don't download the key, you can still use the Lightsail-supplied browser client to securely connect to your instance. Click the icon of a monitor with a shell cursor to do so.

#### DNS, Static IP, Networking

Lightsail has the ability to assign static IPs to instances, and the ability to manage domains and subdomains to direct traffic to them, but a tutorial on their use is beyond the scope of this guide. The `Manage`, `Networking` options will allow you to control the ports available to the instance, perhaps turning SSH off when not in use (by you) for added security, or turning SSL on if a domain certificate is installed to the Apache container.

#### Snapshots

You can stop your OpenEMR instance to take a full copy of it, and then restart it; the snapshot copy will persist, and can be independently started as a separate instance, allowing you to create ad-hoc backups or test beds for OS upgrades, OpenEMR security patches, or to try out procedures like the recovery process before you use them in production.

#### HIPAA Compliance

As of September 2017, AWS Lightsail is not a [HIPAA Eligible Service](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/). HIPAA Covered Entities may not store Protected Health Information on AWS Lightsail, and should confine their use of OpenEMR Cloud Express to demonstration or training use only. (Use of the software on other servers may be possible and should be discussed with your compliance officer.)

### Applying Upgrades and Security Patches

If you're seeking to install a feature release (to upgrade from `5.0.0` to `5.0.1`, for example), see [our upgrade guide](upgrade.md) for the step-by-step process of replacing your OpenEMR container and updating your database. If instead you're applying a sub-version patch for bug-fixes or security updates (like `5.0.1-3` to `5.0.1-4`), walk through the following steps as root.

```
#!/bin/sh

PATCHFILE=5-0-1-Patch-4.zip
OE_INSTANCE=$(docker ps | grep _openemr | cut -f 1 -d " ")

/etc/cron.daily/duplicity-backups
# running OpenEMR Standard? don't forget to make an RDS snapshot
docker exec -it $OE_INSTANCE wget https://www.open-emr.org/patch/$PATCHFILE
docker exec -it $OE_INSTANCE unzip -o $PATCHFILE
docker exec -it $OE_INSTANCE rm $PATCHFILE
# visit http://<your-instance>/sql_patch.php in your browser and proceed
docker exec -it $OE_INSTANCE rm sql_patch.php
```

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

### Non-Lightsail Import

The provided script `ingestion.sh` can import a manually-created OpenEMR backup, the `openemr.tar` file, destroying all current data in the instance without remedy. It's provided in order to ease transitions from Windows XAMPP installations or manual LAMP stacks to the dockerized environment, and although it can serve as part of a backup-and-restore regimen it's more a migration tool that may require remediation (non-LBF customization may be outright missed) before it can shoulder production loads.

Launch it, preferably in a just-launched Lightsail instance, with `./ingestion.sh <backup-name>` after setting it executable.

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and it is encouraged that you explore them as soon as possible.

## Developer Notes

### launch.sh Command-Line Parameters

* *-t* &lt;container-label&gt;: OpenEMR container to load from Docker hub
* *-s* &lt;swap-size-GB&gt;: amount of swap to allocate for small instances; 0 for none
* *-b* &lt;branch-name&gt;: load specific branch of openemr-devops repository
* *-d* &lt;openemr-dockerfile-version&gt;: developer mode
  * uses `build` directive instead of `image` to run specific local repository Dockerfile
  * force MySQL port world-readable

## Support

The OpenEMR [forums](https://community.open-emr.org/) and Slack are available if you have any questions. We'll be happy to help!
