
## AWS LightSail

Base OS, "Ubuntu 16.04", paste, go
```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/stacks/single-server/launch.sh > ./lightsail-launch.sh
chmod +x ./lightsail-launch.sh && sudo ./lightsail-launch.sh
```

Log in with user "admin", password "pass"; step one: *change your password*.

### Instance management notes

 * Should be answering on port 80 inside of five minutes. If it's not...
   * `tail -f /tmp/lightsail-launch.log` to see if it's still running, or where it got stuck
   * Transient build failures are possible if container dependencies are temporarily unavailable, just retry
   * You will need network access, don't try to build from a private IP without NAT egress
 * Connect to webserver container: Alpine has no bash, so `docker ps`, `docker exec -i -t <instance id> /bin/sh`
 * Connect to mysql container: `docker ps`, `docker exec -i -t <instance id> /bin/bash`
 * Review volumes: `docker volume ls`, `docker volume inspect <volume_name>`
 * Visit volume: `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`
 * Scripted in-instance commands: `docker exec $(docker ps | grep mysql | cut -f 1 -d " ") /root/xbackup.sh -t full`
 * Did MySQL crash? The t2.nano 512MB instance is *tight*, and you may need to consider upgrading.
 * Are you running somewhere other than Lightsail? By default we reserve a gig of swap &mdash; you may need to reconsider.
 * Root MySQL credentials are `root`/`root`; you can change these, but be sure to update `config.php` and `innobackupex.cnf`.

### Backups

 * Daily backup initiated from `/etc/cron.daily/duplicity-backup`, you can crontab this instead for better timing
 * restore the most recent backup via `/root/restore.sh`, read *very carefully*
 * rotated backups are stored and recover from `/root/backups`; from here, move them to and from secure off-instance storage
