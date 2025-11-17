Alright, so here's what's going on.

We've got a standard MariaDB compose file here.

* It provides a root password, and we're able to find that and pick it up for later.
* It names the MariaDB data directory as a volume, which is important because we'll need to use trans-project containers on that directory later to accomplish the restore procedure, and that procedure has to be conducted while MariaDB is halted.
* It names an additional volume where we put our backup files, and that volume is bind mounted on the host so backup files can be exfiltrated to offsite storage solutions without interacting with the container.

Installation steps:

* Construct a compose file that makes the above allowances.
* Review and launch `./install.sh`, passing it anything it can't autodetect, specifically the names of the volumes you made in your compose file. (Use the names *in your compose file*, not the final names Docker will assign the resources.) We'll auto-detect as much as we can, but run `--help` anyways to see what it's looking for.
* On your own schedule, run `./backup.sh` to pulse the backup client. This will perform a mariadb-backup run, either starting a fresh full backup or continuing an incremental backup depending on the current state of the newest backup and how many incrementals have already been run against it. (If you allow six incrementals, and you run your backups daily, that's one full backup every week.) These backups will be available in the bind-mounted volume and can be rsynced or copied away as you require. 
* Older backups will be automatically pruned (see `--cycle`) without your attention.

Backup structure:

* Manifest files are paired with their full backups, and contain the list (and order) of the backups that will need to be retrieved to invoke the recovery process.
* Every backup run produces a gzipped xbstream artifact, which we'll load with `mbstream` during the restore operation.
* The backup utility doesn't see the healthcheck file you might've created, so we snatch that up too.
* The LSN directories are part of the ongoing backup creation process but are not themselves part of the backup once they've served their purpose for the next backup.

Recovery procedure:

* Select the backup you want to restore, and locate the manifest that refers to it. 
(You could execute a point-in-time recovery by trimming the manifest of everything after
your last good state.)
* If the backup's already been moved off the server into your own backup solution, restore
it to the bind mount. 
* Call `/recover.sh --manifest <your manifest file>`
* Alternately, don't specify a manifest, and the recovery process will pick the newest backup it can find, handy if you made a backup just before you tried something that didn't work out.
* MariaDB will be stopped, the full and incremental backups will be applied, and normal service will resume.