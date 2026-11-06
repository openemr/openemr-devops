# OpenEMR Doctor

For an OpenEMR install that doesn't work: a blank page, an error 500, setup stopping part-way, a login page without styling, documents or encrypted data that won't open after a move. The doctor names the cause and what to do about it. It only reads: nothing in the install or its database is changed, and it never prints a password or a key.

## Running it

On Docker, in the folder with your `docker-compose.yml`:

```
curl -fsSL https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-doctor/openemr-doctor-docker.sh | bash
```

`openemr-doctor-docker.sh` finds the OpenEMR container by the image it was started from, downloads the newest doctor from this folder (checked against `SHA256SUMS`), and runs it with that container's own PHP:

- inside the container when it is running, so it checks what actually runs, a PHP updated in place or a file edited in the container included;
- when the container won't stay up and `sites/` is on a volume, as in OpenEMR's compose files, from a throwaway container of the same image sharing its volumes and all its networks. That one sees the image and the volumes, not changes made inside the container itself, and says so.

The doctor and its files are copied into the container, not mounted, so a Docker daemon on another host works too.

The report is on stdout; which container it checked, and how, is on stderr. The exit code is 1 when a check fails, 0 when none does, and 2 or more when it couldn't run the doctor. The script runs only from its last line, so a download cut short does nothing.

Without Docker, on the server, with the PHP the web server uses:

```
php openemr-doctor.php --openemr=/var/www/html/openemr [--site=default]
```

The web server can run a different PHP from the command line's. To check that one, copy `openemr-doctor.php` into the OpenEMR folder under a name with a random part of your own, such as `openemr-doctor-7f3a9c2e41b8d605.php`, and open `http://localhost/<folder>/<that name>` in a browser on the server. It answers only requests from the server itself, not through a proxy, and asks to be deleted afterwards. Under its plain name, or that example's, it only asks to be renamed, suggesting a fresh random name: a proxy on the server that adds no forwarding header makes every visitor look local, so the name is the key.

## Options

- `--skip=NAME,...` leaves checks out by name (with the Docker script: `curl … | bash -s -- --skip=documents`). Each one left out prints a `SKIP` line, even when the doctor stops before reaching it, and the summary names it, so it never reads as a pass.
- `--list-checks` prints the names: `php`, `php-security`, `php-extensions`, `php-ini`, `php-libraries`, `page-assets`, `files`, `local-changes`, `local-changes-php`, `documents-folder`, `database-server`, `database-version`, `theme`, `error-display`, `modules`, `encryption-keys`, `documents`, `api-keys`. The install's version, the site, setup and the database connection can't be left out: every other check needs them.
- `--debug` adds where each fact came from, the counts behind each check, and timings (and traces the Docker script).
- For the Docker script: `CONTAINER=name` picks the OpenEMR container when there are several, or one of your own image; `OE=/path` names OpenEMR's folder in it (it otherwise finds it by its `version.php`); `WEB_USER=name` is the web server's user the doctor runs as (`apache`, as in OpenEMR's images, unless given).
- `OPENEMR_DOCTOR_NO_UPDATE_CHECK=1` stops the doctor and the Docker script looking for a newer copy of themselves.

## What it checks

- **PHP**: its version against the release's floor, the install's own `composer.json` (upper bounds included) and the versions OpenEMR's CI tested; PHP's security advisories (such as php2shell, 2026-10-21); the extensions the release's `composer.json` requires; `php.ini` limits and error display.
- **Files**: `vendor/` and every Composer package; the built page assets; every file the release or patch package ships; OpenEMR's own files edited on this server, and whether those still parse and run on this PHP (`scan.php`).
- **The site**: `sqlconf.php` and setup; who can write `documents/`; the database connection, with what an error number means, and SSL (`mysql-ca`, the server's certificate and its names); the database's version and patch against the code's (a patch whose `sql/patch.sql` changes nothing in the database leaves only the patch number behind, which is a note); the theme; OpenEMR's own error-display setting; switched-on modules without files; the encryption keys against the database's; each stored document's file; the API's key pair.

Each check comes from failures reported on the forum and from what OpenEMR's own code needs to start.

## Without internet

Copy `openemr-doctor.php`, `scan.php` and the release facts (below) into a folder named `openemr-doctor-facts/` beside them. The doctor, and the Docker script given a local `openemr-doctor.php`, use them from there, or take `--facts=DIR`.

Every copy says its version and the day it was released. Online, it says when this folder has a newer one. When it can't look, it says how old it is.

## Where the facts come from

The doctor compares an install with the facts for its release:

- the files each release and patch ships, with their git hashes;
- the Composer packages and page assets;
- the PHP floor and extensions, and the PHP and database versions CI tested;
- the settings.

They are generated from OpenEMR's source at each release tag by [openemr-reference](https://github.com/anun333/openemr-reference), about 300 KB per release, and downloaded from the address in `DOCTOR_FACTS` at the top of `openemr-doctor.php`. Without them, the doctor still runs every check that doesn't need them, and reads the PHP floor and extensions from the install's own `composer.json`. PHP's security advisories are a facts file too (`php-security.json`), so a new advisory reaches every copy without a new doctor; the doctor's own list is used without it.

`scan.php` is [php-upgrade-catalogue](https://github.com/anun333/php-upgrade-catalogue)'s scanner, as pinned by openemr-reference: it reads files for what PHP removed and never runs them.

## Changing it

The workflow `test-openemr-doctor.yml` runs the doctor through `openemr-doctor-docker.sh` against `openemr/openemr:latest` and `openemr/openemr:dev`, with a database, on each pull request that touches this folder and every day: inside the running container, from a throwaway container once it is stopped, with the database behind the code, with a doctor that doesn't match `SHA256SUMS`, and on a stopped container without a `sites/` volume. After editing a file here:

- set the same version and date in `openemr-doctor.php` (`DOCTOR_VERSION`, `DOCTOR_DATE`) and `openemr-doctor-docker.sh` (`VERSION`, `DATE`);
- refresh `SHA256SUMS` (`sha256sum openemr-doctor-docker.sh openemr-doctor.php scan.php > SHA256SUMS`), which the Docker script checks what it downloads against.

License: GPL-3.0-or-later.
