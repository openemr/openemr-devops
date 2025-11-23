# OpenEMR Cloud: Do-It-Yourself Appliance Edition

This process will install a fully-functional, secured, preconfigured OpenEMR 7.0.4 instance on your Ubuntu server, providing an embedded MySQL server and rotated, automatic backups of all OpenEMR configuration and health information.

## Installation

### Requirements

* Ubuntu 24.04 server (root access, 2 GB RAM, 20 GB storage)
* Outbound internet access (during installation)

### Directions

From your fresh Ubuntu install, run the following command.
```
curl -s https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/appliance/launch.sh | bash -s
```
This will pause for some time. If you'd like, you can monitor the process by tailing the generated log at `/var/log/appliance-launch.log` from another terminal. Once the installation completes, you may continue.

Login to your server at `https://<server ip>` and ignore the self-signed certificate warning for now.
* Username: `admin`
* Password: `pass`

Installation complete!

## Administration

### General

This repo was installed to the appliance during launch, and you'll find the master compose file for the appliance at `/root/openemr-devops/packages/appliance/docker-compose.yml`. 

* The instance should be answering on port 80 inside of ten minutes. If it's not...
  * `tail -f /var/log/appliance-launch.log` to see if it's still running, or where it got stuck.
  * Transient build failures are possible if container dependencies are temporarily unavailable.
  * You will need network access, don't try to build from a private IP without NAT egress.
  * Check the process list, make sure `auto_configure.php` isn't running before you attempt to log in.
* Need access to the containers? Log into root, and...
  * Apache: `docker compose -p appliance exec openemr /bin/sh`
  * MySQL: `docker compose -p appliance exec mysql /bin/bash`
* Run a quick backup? `/etc/cron.daily/duplicity-backups` as root.
* Modified the compose file? Reload it from this directory with `docker compose up -d`.

### Direct MySQL Access

* `docker compose -p appliance exec mysql mariadb -p`, password `root`, will give you client access.
* Modifying the dockerfile to expose MariaDB's port 3306 or adding in phpMyAdmin will also work.
```
  phpmyadmin:
    restart: always
    image: phpmyadmin
    ports:
    - 8310:80
    environment:
      PMA_HOSTS: mysql
    depends_on:
      mysql:
        condition: service_healthy
```
Relaunch from the appliance directory (above) and connect.

### Version Upgrades

Modify the docker-compose.yml to refer to the new image tag and `up` the stack, as described as above. 

### Let's Encrypt SSL Certificates

After installation, if you've assigned your instance a domain, you may choose to use the onboard Let's Encrypt tooling to acquire an SSL certificate. Add `DOMAIN` and `EMAIL` environmental variables to the OpenEMR declaration stanza of the docker compose file (above) and relaunch.

Though before you make a signficant configuration change, you should always make a...

### Backups

Duplicity is installed to the host machine to manage and rotate backups. It can be configured to send the backups it creates to off-instance storage, but currently does not attempt to do so. `/etc/cron.daily/duplicity-backups` holds the daily backup process that snapshots both the MySQL database, the OpenEMR configuration, and any patient documents that have been created, storing them in `/opt/appliance/backups/out`.

Full backups are made every seven days, with incrementals for the other days.

### Recovering from Backup

It is recommended, in the strongest possible terms, that you familiarize yourself with the recovery process as soon as possible. Launch a backup process, move the created backup files to a fresh instance, and try to recover them &mdash; this test, performed regularly, ensures smooth recovery in the face of catastrophe.

1. If necessary, place the compressed backup archive bundle in `/opt/appliance/backups/out`.
2. As root, launch `/root/openemr-devops/packages/appliance/restore.sh`, and carefully read the warning it supplies you.
3. Take the actions it suggests &mdash; make an image snapshot if possible &mdash; and then, once ready, edit the command as instructed and run it anew.
4. Duplicity will unpack the MySQL backups it's holding, the OpenEMR configuration directory, and any patient documents that have been saved.
5. The MariaDB recovery agent will launch, applying the most recent full backup and all the daily incrementals.
6. Your appliance will restart into the restored state.

See [the MariaDB backup manager](/utilities/mariadb-backup-manager) for more information about the database recovery process.

### Non-Appliance Import

The provided [ingestion script](/utilities/ingestion.sh) can import a manually-created OpenEMR backup, the `openemr.tar` file, destroying all current data in the instance without remedy. It's provided in order to ease transitions from Windows XAMPP installations or manual LAMP stacks to the dockerized environment, and although it can serve as part of a backup-and-restore regimen it's more a migration tool that may require remediation (non-LBF customization may be outright missed) before it can shoulder production loads.

Launch it, preferably in a just-launched appliance, with `./ingestion.sh <backup-name>` after setting it executable.

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and it is encouraged that you explore them as soon as possible.

## Developer Notes

### launch.sh Command-Line Parameters

* *-s* &lt;swap-size-GB&gt;: amount of swap to allocate for small instances; 0 for none
* *-o* &lt;branch-name&gt;: load specific owner of forked openemr-devops repository
* *-b* &lt;branch-name&gt;: load specific branch of openemr-devops repository

## Support

The OpenEMR [forums](https://community.open-emr.org/) and Slack are available if you have any questions. We'll be happy to help!
