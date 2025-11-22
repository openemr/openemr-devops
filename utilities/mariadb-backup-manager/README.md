# mariadb-backup-manager

A generalized backup agent for MariaDB containers running under Docker compose, providing full and incremental backups, consistent hot backup capabilities without downtime, and orchestrated recovery.

## Setup

### Docker Compose Project

You'll need a Docker compose project running a MariaDB container. The enclosed `docker-compose.yml` illustrates several important features you'll need to make sure your project sets up ahead of time.

* You'll need the MariaDB server's root password. If it isn't in the server environment, you'll need to provide it in the install step.
* It names the MariaDB data directory as a volume, which we'll call the database volume.
* It names an additional volume where we put our backup files, bind mounted for direct access from the hose. We'll call this the database backup volume.

You don't have to bind mount the backup volume if you don't have any plans to copy the files elsewhere, though it's not especially safe. In any case, if you do specify a bind mount, make sure to create it on the host.

Either way, launch the project, then use `docker compose ps` to find the name of the project. We'll need that later.

### Installation

From this directory, run `./install.sh --help` to get a sense of what we need to pass in, and `./install.sh -p <compose project name> [further options...]` to get started. We'll autodetect what we can, leaning on docker compose introspection to fill things in, and if you've only got one docker-compose project on your system and that project only has one MariaDB container, there's a lot of fields you might not have to specify. 

The installer will save our current state, and install a small agent wrapper on the MariaDB container. If you update your container later, or otherwise significantly change some part of your environment or preferences, you may rerun the installer without unforseeable consequences.

## Usage

### Backup

* Run `./backup.sh` in this directory to trigger a backup. 

Depending on how you set the thresholds for your incremental backups and the current state of the export directory, the backup system will run a full or incremental backup using `mariadb-backup`, a fork of the venerable Percona XtraBackup tool, and stream the results out to timestamped artifacts in your bind mount. You may cron this process or integrate it into an existing backup process. 

After the backup runs, backups older than the number of cycles you specified will be pruned. If you specify two cycles to hold, there will never be more than three full backups on the volume.

### Restore

* Run `./restore.sh` in this directory with either no arguments (for the most recent backup), or `--manifest <manifest file>`, to trigger an immediate in-place restore. Your compose project will be stopped, the agent will launch an anonymous container, and the backups from the manifest will be sequentially applied before your MariaDB is restarted in its new state.

Note that *any* use of the restore agent, including `--dry-run`, will bounce your database container. The restore process is destructive and absolute, so to the extent possible, please back up your system before proceeding.

## Implementation Details

### Backup Structure

* Manifest files are paired with their full backups, and contain the list (and order) of the backups that will need to be retrieved to invoke the recovery process.
* Every backup run produces a gzipped xbstream artifact, which we'll load with `mbstream` during the restore operation.
* The backup utility doesn't see the healthcheck file you might've created, so we snatch that up too.
* The LSN directories are part of the ongoing backup creation process but are not themselves part of the backup once they've served their purpose for the next backup.

### Container Healthcheck

The handling of the healthcheck file is more fragile than I'd like, but MariaDB doesn't expose a good way to renew it. If, after a restore, Docker thinks your instance is unhealthy but it's doing fine, and the logs show somebody banging on the door every few seconds, the healthcheck may need manual remediation.

### Technical Overview

There's only three parts to this that matter.

* The installer, which works out everything we'll need to know later and saves this information in `properties` files that get passed into the containers later. 
* The backup agent, which is passed into the permanent container and consumes the properties files and a root-bearing MariaDB configuration file to run the backup process, looking at the manifests and deciding what kind of backup we'll run. 
* The restore agent, which is passed into an anonymous container while MariaDB is down and does the surgery on the database volume mount, applying backups in order and getting the whole affair back where the permanent container can pick back up when it's turned back on.

A good chunk of the complexity is because we've strived for a general solution, but it'd be entirely reasonable for an end-user to hardcode their own requirements (like different root-credential handling) or a more nuanced manifest format, or to send the backup files directly to a logging destination without requiring a bind mount. (Though please review MariaDB's notes on [LSN handling](https://mariadb.com/docs/server/server-usage/backup-and-restore/mariadb-backup/incremental-backup-and-restore-with-mariadb-backup) if you pursue this.)

### On Version Upgrades

If you upgrade the version of MariaDB you're using, my advice.

* Rerun `install.sh` to pick up your new version from the compose file.
* Force a full backup because we don't try to navigate version upgrades mid-recovery.
* Let me know how it went for you.
