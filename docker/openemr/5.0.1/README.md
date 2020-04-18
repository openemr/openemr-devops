# OpenEMR Official Docker Image

The docker image is maintained at https://hub.docker.com/r/openemr/openemr/
(see there for more details)

## Tags

Tags and their current aliases are shown below:

 - `5.0.2`: next
 - `5.0.1`: latest

It is recommended to specify a version number in production, to ensure your build process pulls what you expect it to.

## How can I just spin up OpenEMR?

*You **need** to run an instance of mysql/mariadb as well and connect it to this container! You can then either use auto-setup with environment variables (see below) or you can manually set up, telling the server where to find the db.* The easiest way is to use `docker-compose`. The following `docker-compose.yml` file is a good example:
```yaml
# Use admin/pass as user/password credentials to login to openemr (from OE_USER and OE_PASS below)
# MYSQL_HOST and MYSQL_ROOT_PASS are required for openemr
# MYSQL_USER, MYSQL_PASS, OE_USER, MYSQL_PASS are optional for openemr and
#   if not provided, then default to openemr, openemr, admin, and pass respectively.
version: '3.1'
services:
  mysql:
    restart: always
    image: mariadb:10.2
    command: ['mysqld','--character-set-server=utf8']
    volumes:
    - databasevolume:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: root
  openemr:
    restart: always
    image: openemr/openemr:5.0.2
    ports:
    - 80:80
    - 443:443
    volumes:
    - logvolume01:/var/log
    - sitevolume:/var/www/localhost/htdocs/openemr/sites
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: openemr
      MYSQL_PASS: openemr
      OE_USER: admin
      OE_PASS: pass
    depends_on:
    - mysql
volumes:
  logvolume01: {}
  sitevolume: {}
  databasevolume: {}
```
[![Try it!](https://github.com/play-with-docker/stacks/raw/cff22438cb4195ace27f9b15784bbb497047afa7/assets/images/button.png)](http://play-with-docker.com/?stack=https://gist.githubusercontent.com/bradymiller/b629738d5d9aee6c2e8c036e7916c719/raw/1e5b63b3963334a11c7d54e6c466cbf9197ac4ff/openemr-501-docker-example-docker-compose.yml)

## Environment Variables

Required environment settings for auto installation are `MYSQL_HOST` and `MYSQL_ROOT_PASS` (Note that can force `MYSQL_ROOT_PASS` to be empty by passing as 'BLANK' variable).

Optional settings for the auto installation include database parameters `MYSQL_ROOT_USER`, `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_DATABASE`, and openemr parameters `OE_USER`, `OE_PASS`.

Can override auto installation and force manual installation by setting `MANUAL_SETUP` environment setting to 'yes'.

Can use both port 80 and 443. Port 80 is standard http. Port 443 is https/ssl and uses a self-signed certificate by default; if assign the `DOMAIN` and `EMAIL`(optional) environment settings, then it will set up and maintain certificates via letsencrypt.

## Where to get help?

For general knowledge, our [wiki](https://www.open-emr.org/wiki) is a repository of helpful information. The [Forum](https://community.open-emr.org/) are a great source for assistance and news about emerging features. We also have a [Chat](https://www.open-emr.org/chat/) system for real-time advice and to coordinate our development efforts.

## How can I contribute?

The OpenEMR community is a vibrant and active group, and people from any background can contribute meaningfully, whether they are optimizing our DB calls, or they're doing translations to their native tongue. Feel free to reach out to us at via [Chat](https://www.open-emr.org/chat/)!
