# Migrating a legacy Express Plus or Lightsail install

This document covers stacks deployed **before November 2025**, which run MySQL 5.7 inside the retired `openemr/mysql-xtrabackup` container. If that describes your instance, the recovery procedure in the current [README](README.md) does not apply to you, and you cannot reach a current appliance by changing image tags.

> **Status:** validated end-to-end on 2026-10-07/08 against a live production practice (~2,500 patients, ~5 GB database, OpenEMR 7.0.3 → 8.4.1, MySQL 5.7.28 → MariaDB 11.8). Practice downtime was approximately nine minutes. The procedure below incorporates every correction that run surfaced. Rehearse on a copy before running it against your own practice regardless.

## Am I affected?

On the instance:

```
docker compose ls
docker compose -p lightsail ps
```

You are on a legacy stack if any of the following are true:

* The compose project is named `lightsail` rather than `appliance`.
* `docker compose ps` shows `openemr/mysql-xtrabackup`.
* `mysql -V` inside the database container reports 5.7.x.
* `docker volume ls` shows `lightsail_sqlbackup`, `lightsail_sitevolume`, `lightsail_databasevolume`, `lightsail_logvolume01`.
* `/etc/cron.daily/duplicity-backups` calls `/root/xbackup-wrapper.sh` via `docker exec`.

The OpenEMR application on these stacks is typically 7.0.x, with `--character-set-server=utf8` on the database — meaning **every table is utf8mb3**, not utf8mb4.

## Why this is a migration and not an upgrade

**The database engine changes.** Legacy runs MySQL 5.7; current runs MariaDB 11.8. There is no in-place path between them. The data must move as a logical dump. (Note that OpenEMR 8.4.0 raised the supported floor to MariaDB 10.11+ / MySQL 8.4+, so staying on 5.7 is no longer an option on current releases at all.)

**Your existing backups cannot be restored into the new stack.** Legacy backups capture the database as Percona XtraBackup 2.4 *physical* output — a copy of the MySQL 5.7 data directory. The current `restore.sh` replays mariabackup manifests. The formats are not interchangeable, and physical backups cannot cross engines at all. The Recovery stack template becomes useful to you only *after* this migration, not as a vehicle for it.

**The character set changes.** Because `sql/database.sql` declares no charset, your tables inherited utf8mb3 from the server. A naive dump and load into the utf8mb4 appliance produces utf8mb3 tables in a utf8mb4 server: it works, it looks fine, and it silently keeps the 3-byte limitation. This must be handled deliberately — and on MariaDB ≥ 11.5 there is a second collation trap, covered in Hop A.

## Why this is time-sensitive

The `openemr/mysql-xtrabackup` image **cannot be rebuilt**. Its Dockerfile is `FROM debian:jessie`, installs MySQL from `repo.mysql.com/apt/debian/ jessie`, and fetches GPG keys from `ha.pool.sks-keyservers.net`, which has been offline since 2021. The only reason legacy stacks function is that a prebuilt image remains published on Docker Hub.

Consequently, a legacy site's disaster recovery depends on that Docker Hub tag continuing to exist. If it is ever pruned, the physical backups become unrestorable and the only remaining path is a logical dump taken from a still-running container. **Take and retain a logical dump now, independent of whether you migrate today.**

## What your legacy backups actually contain

The legacy duplicity job archives two volume mountpoints:

* `lightsail_sqlbackup` — XtraBackup physical output. Not usable in the new stack.
* `lightsail_sitevolume` — the OpenEMR `sites/` tree: patient documents, `sqlconf.php`, and the `docker-version` marker. **This is usable and you will reuse it.**

Two exclusions apply (`recovery`, `prerecovery-mysql-datadir`), and the raw MySQL data directory (`lightsail_databasevolume`) is *not* in the archive.

> **arm64 warning.** The legacy backup script skipped the database entirely on arm64:
> ```
> if [[ $(dpkg --print-architecture) != arm64 ]]; then
>   docker exec ... /root/xbackup-wrapper.sh
> fi
> ```
> and the legacy restore exits before the database step on arm. If your instance is arm64, **you have no database backups at all** — only `sites/`. A logical dump from the running container is your only copy. Treat this as urgent.

> **Local-disk warning.** If `/root/cloud-backups-enabled` is absent, the legacy duplicity job has been writing to `file:///root/backups/` on the instance itself — "off-site" in name only. Verify where your archives actually live before trusting them.

## Prerequisites

Confirm all of these before touching anything:

* **Compose v2.** `docker compose version` must work (space, not hyphen). Compose v1 is EOL, names containers differently (`_` vs `-`), and lacks the label-based project operations this guide depends on. Do not install the `docker-compose` 1.x package your distribution may suggest.
* **Application credentials.** You need an OpenEMR login to validate the migrated site. Infrastructure access alone gets you through the technical verification, but the clinical pass — charts, documents, billing — needs a real user. Arrange this *before* the window, not during it.
* **The practice informed and idle.** Agree on a window; verify nobody is working at cutover time (procedure below).
* **Disk budget: ~2× the database size, not on the root volume.** The dump (larger than the datadir if it holds blob data, thanks to `--hex-blob`) plus a working copy will not fit on a stock 16 GB root. Stage everything on the data volume. The Docker data root is deliberately non-traversable by non-root users — create your staging directory with sudo and keep working as root (or prefix everything); do not loosen the Docker root's permissions.
* **EBS snapshots of all attached volumes.** In the console, use Create snapshot with resource type **Instance** — one click snapshots every attached volume as a consistency set. Wait for **Completed** before anything destructive. (The console will likely flag these older launches as *Not encrypted*; put "migrate to encrypted volumes" on the post-migration list — these very snapshots can later be copied-with-encryption and swapped in.)

Paths in this guide assume a staging directory such as `/mnt/docker/migration` owned by root; adjust to your layout.

## Strategy: two hops, side by side

Do not combine the engine change with the version upgrade. Split it:

**Hop A — engine swap, same OpenEMR version.** MySQL 5.7 → MariaDB, OpenEMR stays at your current 7.0.x.
**Hop B — version upgrade, same engine.** OpenEMR 7.0.x → current, MariaDB unchanged.

The payoff for this ordering: Hop A puts the site inside the tooling the project actually validates, so Hop B — the riskier operation — is the one with a rehearsed rollback behind it.

**Build the new stack beside the old one, not over it.** The new stack is its own compose project in its own directory, publishing on side ports (8080/8443), while the legacy stack keeps serving production untouched. Everything up to the cutover is zero-downtime: capture, convert, load, verify, even the Hop B upgrade all happen on the side, and users land on an already-upgraded, already-verified system. The legacy project directory (`~/openemr-devops/packages/lightsail/`, with its `docker-compose.yml → docker-compose.prod.yml` symlink) is **never edited** — it is your rollback definition.

### The version markers cooperate with this

The container's `check_upgrade()` compares `/root/docker-version` in the image against `sites/default/docker-version` in your site, and fires the `fsupgrade` chain only when the image's number is strictly greater. The numbers themselves change between releases (7.0.x images carry `7`; 8.4.1 carries `15`), so do not rely on a lookup table — the invariant is:

> **Site marker == the image's own `/root/docker-version` ⇒ restarts are inert. Image greater ⇒ the upgrade chain fires once.**

Check the image's marker directly: `docker exec <container> cat /root/docker-version`.

Hop A therefore pins the new stack to the **same 7.0.x tag your site runs** (use 7.0.3 if that is what you have — do not drift to 7.0.4/7.0.5, which would put newer code over your schema without triggering anything, since they share the marker). Hop B is then a tag change to the current release, which fires the chain exactly once.

## Hop A — engine swap

### A1. Snapshot everything

Multi-volume EBS snapshot per Prerequisites. Confirm **Completed** in the console. Nothing below is reversible without it.

### A2. Take a logical dump

Dump with binary passthrough so no transcoding occurs — the stored bytes are already valid UTF-8, and you want them to arrive unchanged. This also makes the later `sed` safe: row data travels hex-encoded or raw, so text surgery only ever touches DDL.

```
docker exec lightsail-mysql-1 mysqldump \
  --default-character-set=binary --skip-set-charset \
  --single-transaction --routines --triggers --events --hex-blob \
  -uroot -p<rootpw> openemr > /mnt/docker/migration/openemr-legacy.sql

tail -1 /mnt/docker/migration/openemr-legacy.sql     # expect "Dump completed"
grep -c 'CREATE TABLE' /mnt/docker/migration/openemr-legacy.sql   # note the count; you will re-check it
```

Compress a copy and move it off the instance now. **This file is retained permanently** — it is the only copy of the legacy database that does not depend on the unrebuildable Docker image staying published. If the instance has the CloudFormation S3 bucket, note that the instance role typically allows `s3:PutObject` only under the `Backup/` prefix — upload there (e.g. `s3://$BUCKET/Backup/MIGRATION-<date>-...`) with the stack's KMS key (`--sse aws:kms --sse-kms-key-id ...`). Foreign files in that prefix are safe: duplicity's retention only deletes files matching its own naming scheme.

Optional but recommended: check what you are hauling. Legacy sites often carry a multi-GB audit `log` table; trimming it pre-dump shrinks every later step.

```
docker exec lightsail-mysql-1 mysql -uroot -p<rootpw> -N -e "
SELECT table_name, ROUND((data_length+index_length)/1024/1024) AS mb
FROM information_schema.tables WHERE table_schema='openemr'
ORDER BY 2 DESC LIMIT 10;"
```

Also record baseline row counts for later comparison (patient_data, form_encounter, billing, documents at minimum).

### A3. Extract the sites tree

```
SITEVOL=$(docker volume inspect lightsail_sitevolume -f '{{.Mountpoint}}')
cat $SITEVOL/default/docker-version            # must match your running image's marker — stop if absent
tar czf /mnt/docker/migration/openemr-sites.tar.gz -C $SITEVOL .
tar tzf /mnt/docker/migration/openemr-sites.tar.gz | wc -l    # sanity: roughly matches find $SITEVOL | wc -l
grep -E "\\\$(host|login|pass|dbase)" $SITEVOL/default/sqlconf.php   # record these; the new stack must match them
```

If `docker-version` is missing, create it containing your image's marker before restoring — an absent marker reads as `0` and the install path may stamp it current, leaving new code over an old schema with no upgrade ever having run.

### A4. Convert the schema charset in the dump

Do this before loading, not after: the old schema is the smallest it will ever be. Work on a copy — never sed the retained original.

```
cp /mnt/docker/migration/openemr-legacy.sql /mnt/docker/migration/openemr-mb4.sql
sed -i \
  -e 's/DEFAULT CHARSET=utf8\([^m]\|$\)/DEFAULT CHARSET=utf8mb4\1/g' \
  -e 's/CHARACTER SET utf8\([^m]\|$\)/CHARACTER SET utf8mb4\1/g' \
  -e 's/COLLATE=utf8_/COLLATE=utf8mb4_/g' \
  -e 's/COLLATE utf8_/COLLATE utf8mb4_/g' \
  -e 's/character_set_client = utf8 /character_set_client = utf8mb4 /g' \
  -e 's/DEFINER=[^ ]* //g' \
  /mnt/docker/migration/openemr-mb4.sql
```

Notes on the expressions:

* The `character_set_client` line is required: mysqldump emits `/*!40101 SET character_set_client = utf8 */;` before **every** CREATE TABLE even with `--skip-set-charset`. It is harmless in itself, but without rewriting it the verification below can never reach zero.
* Stripping `DEFINER` avoids restore failures on views/routines/triggers stamped with a MySQL account that will not exist in MariaDB.

Verify — all three, not just the first:

```
grep -c 'utf8[^m]' /mnt/docker/migration/openemr-mb4.sql        # expect 0
grep -c 'CREATE TABLE' /mnt/docker/migration/openemr-mb4.sql    # unchanged from A2
diff <(grep -o 'INSERT INTO `[^`]*`' /mnt/docker/migration/openemr-legacy.sql | sort | uniq -c) \
     <(grep -o 'INSERT INTO `[^`]*`' /mnt/docker/migration/openemr-mb4.sql | sort | uniq -c)    # expect no output
```

The diff proves the sed touched only DDL: identical INSERT distribution means no row data was altered.

### A5. Stand up the side-by-side stack

Create the new project directory (e.g. `/mnt/docker/migration/appliance`) and a compose file shaped on the current appliance package, with these deliberate choices:

```yaml
name: appliance

services:
  mysql:
    image: mariadb:11.8
    restart: unless-stopped
    command: ['mariadbd', '--character-set-server=utf8mb4', '--character-set-collations=utf8mb4=utf8mb4_general_ci']
    environment:
      MARIADB_ROOT_PASSWORD: root
    volumes:
      - databasevolume:/var/lib/mysql

  openemr:
    image: openemr/openemr:7.0.3        # pin to YOUR current version — see marker discussion
    restart: unless-stopped
    ports:
      - "8080:80"
      - "8443:443"
    volumes:
      - sitevolume:/var/www/localhost/htdocs/openemr/sites
      - logvolume:/var/log
      - letsencrypt:/etc/letsencrypt
      - sslvolume:/etc/ssl
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr               # must match sqlconf.php $login
      MYSQL_PASS: <from sqlconf.php>    # must match sqlconf.php $pass
      OE_USER: admin
      OE_PASS: <random throwaway>
      # DOMAIN: emr.example.org         # keep commented until cutover — see below
      # EMAIL: admin@example.org
      OPENEMR_DOCKER_ENV_TAG: appliance
    depends_on:
      - mysql

volumes:
  databasevolume:
  sitevolume:
  logvolume:
  letsencrypt:
  sslvolume:
```

Why each choice:

* **`name: appliance`** pins the project in the file, so a forgotten `-p` cannot bind these definitions to the wrong project. (Compose resolves the *file* from the current directory and the *project* from `-p`/`name:`/directory name — they can disagree silently.)
* **`--character-set-collations=utf8mb4=utf8mb4_general_ci`** is required on MariaDB ≥ 11.5. mysqldump omits COLLATE on tables that used their charset's default, and bare `CHARSET=utf8mb4` then takes the *charset's* default collation — which MariaDB 11.5+ changed to `uca1400_ai_ci`, silently overriding your database-level COLLATE. Without this flag every table loads as uca1400, the verification in A7 fails, and future upgrade SQL that specifies `utf8mb4_general_ci` explicitly would leave you with mixed collations.
* **The service stays named `mysql`** because the restored `sqlconf.php` says `$host = 'mysql'` and compose publishes services under their service names per-project. Keep the name, and the restored config connects with zero edits; the two projects' networks are separate, so there is no collision with the legacy stack's `mysql`.
* **Cert paths get named volumes.** The legacy compose names neither `/etc/letsencrypt` nor `/etc/ssl` — they are image-declared *anonymous* volumes, silently destroyed on container replacement. Name them.
* **`DOMAIN`/`EMAIL` stay commented out until cutover.** With `DOMAIN` set, the entrypoint runs certbot — which cannot succeed from the side ports — **and a certbot failure exits the container**. The restart policy then loops it, and every lap burns one of Let's Encrypt's five failed validations per account+hostname per hour, potentially locking the domain out of issuance right when cutover needs it.
* **`MYSQL_USER`/`MYSQL_PASS` must match the restored sqlconf exactly** — they are consulted on every boot (readiness checks, upgrades). **`OE_USER`/`OE_PASS` are fresh-install-only** — set them to throwaway random values so that if the app container ever accidentally starts against an empty sites volume, the resulting fresh install cannot be entered with `admin`/`pass`.

Bring up **the database service only**:

```
cd /mnt/docker/migration/appliance
docker compose up -d mysql
until docker exec appliance-mysql-1 mariadb -uroot -proot -e 'SELECT 1' >/dev/null 2>&1; do sleep 2; done; echo ready
```

Use that readiness poll (or watch for `mariadbd: ready for connections` in the logs) after **every** start or recreate of the database service — issuing SQL into a still-initializing container is the most common self-inflicted error in this procedure.

### A6. Load, grant, seed — in this order

The openemr container must never start against an empty sites volume (it would run a fresh install over your loaded database). The order is: load database → create grants → seed sites → only then start the app.

```
docker exec -i appliance-mysql-1 mariadb -uroot -proot -e \
  "CREATE DATABASE openemr CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
time docker exec -i appliance-mysql-1 mariadb -uroot -proot openemr < /mnt/docker/migration/openemr-mb4.sql
```

Expect minutes, not hours (a ~5 GB dump loads in under five minutes on gp3-class storage). If it errors, capture the statement, fix at the dump level, `DROP DATABASE` and reload clean — never patch a half-loaded database.

```
docker exec -i appliance-mysql-1 mariadb -uroot -proot -e \
  "CREATE USER 'openemr'@'%' IDENTIFIED BY '<pass from sqlconf>';
   GRANT ALL PRIVILEGES ON openemr.* TO 'openemr'@'%'; FLUSH PRIVILEGES;"
```

(Grants live outside the database and survive any later DROP/reload.)

Seed the sites volume:

```
APPSITE=$(docker volume inspect appliance_sitevolume -f '{{.Mountpoint}}')
tar xzf /mnt/docker/migration/openemr-sites.tar.gz -C $APPSITE

cat $APPSITE/default/docker-version                       # marker intact
grep -E "\\\$(host|login|dbase)" $APPSITE/default/sqlconf.php
ls $APPSITE/default/documents | head                      # patient documents present
diff <(find $SITEVOL -type f | sed "s|$SITEVOL||" | sort) \
     <(find $APPSITE -type f | sed "s|$APPSITE||" | sort)  # expect empty
```

Ownership from tar's preservation is sufficient — the entrypoint chowns the tree to its web user and normalizes permissions on every start.

First app start, watched live:

```
docker compose up -d openemr
docker compose logs -f openemr
```

**Good boot:** the entrypoint finds the configured site and says nothing about installing or upgrading — the silence is the success — then runs its permission sweep and prints `Starting Apache!`. **Bad boot — stop immediately:** anything about setup, site creation, or `Upgrade detected`.

### A7. Verify before declaring Hop A done

Database level:

```
docker exec appliance-mysql-1 mariadb -uroot -proot -N openemr -e "
SELECT @@version, @@character_set_server;
SELECT table_collation, COUNT(*) FROM information_schema.tables
 WHERE table_schema='openemr' GROUP BY table_collation;         -- exactly one row: utf8mb4_general_ci
SELECT COUNT(*) FROM information_schema.columns
 WHERE table_schema='openemr' AND character_set_name LIKE 'utf8mb3%';  -- 0
SELECT 'patient_data', COUNT(*) FROM patient_data UNION ALL
SELECT 'form_encounter', COUNT(*) FROM form_encounter UNION ALL
SELECT 'documents', COUNT(*) FROM documents;"                   -- match your A2 baseline
```

Application level, on the side port (`https://<instance>:8443`). On AWS the side port is **not reachable by default** — and since this staging copy holds live PHI, prefer an SSH tunnel (`ssh -L 8443:localhost:8443 user@instance`, then browse `https://localhost:8443`) over opening the security group. Expect a self-signed certificate warning (DOMAIN is commented out — this is correct at this stage).

Log in with real credentials: open a patient chart (one with accented or non-Latin names if any exist — mojibake here means a transcoding error in A2, not a display bug), open a stored document, run one report, and check the billing screens.

## Cutover and Hop B

The ordering rule that governs everything: **any final data sync happens before Hop B.** A fresh dump from the legacy stack is old-schema; loading it after the upgrade would destroy the upgrade.

### C1. Idle check

```
docker exec lightsail-mysql-1 mysql -uroot -p<rootpw> -N openemr -e \
  "SELECT MAX(id) FROM log; SELECT MAX(date) FROM form_encounter;"
```

Compare against what your A2 dump captured — **not** against the new stack, whose `log` your own staging logins have inflated. If the legacy side advanced, inspect before concluding someone is working: the `comments` column is base64 — decode a sample. An abandoned browser tab generates hours of `dated_reminders` polling and ends in a forced-timeout logout; that is idle in fact despite the row count. Re-sync regardless: the final dump should be authoritative, not reasoned-about.

### C2. Final sync (if anything drifted)

Repeat A2's dump (fresh file), A4's **full** sed including the `character_set_client` expression, then on the new stack: readiness poll, `DROP DATABASE openemr; CREATE DATABASE ... COLLATE utf8mb4_general_ci;`, load, re-verify counts. Re-run the sites tree diff and copy across any files the legacy side gained. Rehearsed, this is ~15 minutes.

### C3. Hop B rollback point

```
docker exec appliance-mysql-1 mariadb-dump -uroot -proot \
  --single-transaction --routines --triggers --events openemr | gzip \
  > /mnt/docker/migration/openemr-hopA-verified.sql.gz
```

### C4. Hop B — on the side ports

Users will land on an already-upgraded, already-verified stack; the upgrade itself costs zero production downtime.

```
sed -i 's|openemr/openemr:7.0.3|openemr/openemr:<current>|' docker-compose.yml
docker compose up -d openemr
docker compose logs -f openemr
```

What to expect: the pull, then `check_upgrade()` sees the image marker above the site marker and runs the `fsupgrade` chain — `sql_upgrade` stepping through every intermediate release. Two things about how this *looks*:

* **It is long and it is quiet.** A multi-major upgrade on a ~5 GB database ran ~4 minutes before Apache in the validation run (the 8.4.x entrypoint prints `[TIMING]` lines — a normal non-upgrade boot is ~10 s for comparison). Individual ALTERs on large tables sit silent for a minute or more. Silence with the container Up is work.
* **It looks like a loop and usually isn't.** The chain prints a near-identical block per version plus walls of `Skipping section #IfMissingColumn ...` lines — that is the idempotent-upgrade machinery confirming guards, not repetition. Before concluding it is looping, check `docker inspect -f '{{.RestartCount}}' <container>` and grep-count a chain line that should appear once. (And if it genuinely did re-run: the upgrade SQL's guards make second passes skip what the first applied — it is not corrupting anything.)

As of 8.4.0, the upgrade scripts abort loudly on failure rather than continuing past errors. Verify the destination as well as the journey:

```
docker exec appliance-openemr-1 cat /var/www/localhost/htdocs/openemr/sites/default/docker-version
docker exec appliance-openemr-1 cat /root/docker-version            # the two must now be EQUAL
docker exec appliance-mysql-1 mariadb -uroot -proot -N openemr -e "SELECT v_major, v_minor, v_patch, v_database FROM version;"
docker exec appliance-openemr-1 grep '\$v_database' /var/www/localhost/htdocs/openemr/version.php
```

The `v_database` in the table must **equal** the value in `version.php` — that equality is the proof the schema upgrade ran to completion. Marker equality is the proof restarts are now inert. Then log in on the side port once more.

If Hop B fails: stop the service, reload the C3 dump, revert the tag, investigate. The legacy stack has been serving production untouched the whole time.

### C5. The flip (~10 minutes of downtime — do not start unless you can finish)

```
# 1. Make "stopped" survive reboots, then stop the legacy stack.
docker update --restart unless-stopped lightsail-openemr-1 lightsail-mysql-1
docker compose -p lightsail stop
```

Use **`stop`, never `down`**, at cutover: `stop` leaves the containers whole, so rollback is `docker compose -p lightsail start` — seconds, no recreation. The `docker update` first matters because the legacy compose sets `restart: always`, and an *always*-container that was manually stopped **resurrects on daemon restart** — a 3 AM host reboot would bring the old stack back up to fight the new one for ports 80/443. `unless-stopped` stays down. (`down` — without `-v`, ever — is for decommission weeks later. These label-based `-p` operations work from any directory under compose v2.)

```
# 2. Real ports, DOMAIN back on, recreate.
sed -i 's/"8080:80"/"80:80"/; s/"8443:443"/"443:443"/; s/^\( *\)# DOMAIN:/\1DOMAIN:/; s/^\( *\)# EMAIL:/\1EMAIL:/' docker-compose.yml
docker compose up -d openemr
docker compose logs -f openemr
```

Markers are equal, so no upgrade fires; certbot now has a real port 80 and (if DNS already points at this instance) issues cleanly — the validation run's whole boot was ~10 seconds, certificate included, with renewal scheduled by the image.

**If certbot fails here** (most likely a rate limit from earlier failed attempts): the container will exit and loop. Deploy the parachute — stop the service, re-comment DOMAIN/EMAIL, `up -d`: the practice is live on the self-signed certificate within a minute, fully functional, only the browser warning differs. Restore DOMAIN and recreate an hour later.

### C6. Confirm from the outside

`https://<real domain>` from a machine off the instance: certificate, login page rendering the practice's name (that title comes from the migrated database — seeing it is itself a verification), real login if you hold credentials. Then have the practice do a clinical click-through — chart, stored document, billing — at first opportunity, and give them the triage frame: data-shaped oddities (missing values, wrong characters/dates) point at the migration and get checked against the intact legacy copy; behavior-shaped ones (UI, moved features) are almost certainly the several major versions of application change that just landed, not migration damage.

## Close-out

**Immediately (same night):**

* **Post-flip dump, off-box.** Until a backup job exists, it is the only copy of the upgraded database anywhere.
* **Replace — do not merely disable — the legacy backup cron.** Two reasons it must not keep running: its stage 1 greps `docker ps` for any container matching `mysql` and will `docker exec` into your *new* database container (where its wrapper script does not exist); worse, its stage 2 would keep "backing up" the frozen legacy volumes with healthy-looking timestamps while `remove-all-but-n-full` ages out the chains that hold the real pre-migration state — a healthy-looking backup of the wrong thing. But plain disabling leaves the instance with zero automated backups, so replace the script body with an interim that is correct for the new stack:

```bash
#!/bin/bash
# Interim post-migration backup: dumps the new DB, ships via duplicity.
# Replace with mariadb-backup-manager when convenient.
set -e
STAGING=/mnt/docker/migration/nightly
mkdir -p $STAGING
docker exec appliance-mysql-1 mariadb-dump -uroot -proot \
  --single-transaction --routines --triggers --events openemr > $STAGING/openemr-nightly.sql
S3=$(cat /root/.cloud-s3.txt)
KMS=$(cat /root/.cloud-kms.txt)
PASSPHRASE=$(aws s3 cp s3://$S3/Backup/passphrase.txt - --sse aws:kms --sse-kms-key-id $KMS)
export PASSPHRASE
duplicity --full-if-older-than 9D --include $STAGING \
  --include $(docker volume inspect appliance_sitevolume -f '{{.Mountpoint}}') \
  --exclude '**' / boto3+s3://$S3/Backup/appliance
duplicity remove-all-but-n-full 2 --force boto3+s3://$S3/Backup/appliance
```

  Details that matter, each learned the hard way:
  * **Dump raw, not gzipped.** Gzip output is not rsyncable — a few changed rows shift every later byte and duplicity ships ~the whole file nightly (a ~450 MB "incremental" of a quiet night, observed). Raw .sql deltas down to what actually changed; duplicity's gpg stage compresses each volume anyway, and a restore loses the gunzip step. Budget staging disk at database size. (Second-best: `gzip --rsyncable`.)
  * **The target nests under `Backup/`** because the CloudFormation `WebserverRole` allows `s3:PutObject` on `Backup/*` only — a sibling prefix gets AccessDenied. Prefix separation inside `Backup/` is sufficient: duplicity retention is per-target-URL and never evaluates the legacy chains sitting above it (nor vice versa), so the final pre-migration archives age on *your* schedule.
  * **No key setup is needed** — the exported PASSPHRASE puts duplicity in symmetric-gpg mode, the same mechanism the legacy chain used; a new prefix inherits it with zero keyring work.
  * **Run it once by hand** and confirm a full lands in the new prefix before trusting the night.
* Verify the migration artifacts (legacy dump, hopA dump, post-flip dump, sites tarball) are off-box, then delete the uncompressed working copies to reclaim disk.

**Next morning — verify the backup actually ran, in three layers (the logs are the least reliable layer):**

1. *Did cron fire?* Note Ubuntu's crontab runs the dailies as `test -x /usr/sbin/anacron || run-parts ...` — with no anacron installed there is no anacron spool stamp, and `run-parts --report` only logs jobs that print. An empty log grep proves nothing either way.
2. *Did the script succeed?* Fresh timestamp on the staging dump.
3. *Did it land?* New `duplicity-inc.*` + signatures in the S3 prefix, or `duplicity collection-status` showing the chain. **Check the chain, never the cron** — a backup chain can be silently dead for weeks while cron reports success.

**Within days/weeks:**

* Swap the interim script for `mariadb-backup-manager` per the appliance package, and rehearse a restore.
* Rotate the database root password off the package default.
* Close any staging ports opened in the security group; remove any orphaned partial uploads from failed prefix attempts.
* Plan the move to encrypted EBS volumes (copy the pre-migration snapshots with encryption enabled, swap volumes in a maintenance window).
* Pick a legacy decommission date. Until then the stopped stack is your deep rollback. At decommission: `docker compose -p lightsail down` — **never `-v`** — and retain the volumes, the stack's KMS key, and the S3 archives for as long as your records-retention policy requires. Deleting the KMS key renders the retained archives and final snapshots permanently undecryptable, which for a covered entity is a retention violation, not a cleanup step.
* Keep the A2 logical dump permanently, independent of everything else.

## Support

Ask on the OpenEMR [forums](https://community.open-emr.org/) or Slack before improvising on a live practice. If you run this migration, please report anything that differed from the above so this document stays validated.
