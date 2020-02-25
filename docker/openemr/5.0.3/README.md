# OpenEMR Official Docker Image

The docker image is maintained at https://hub.docker.com/r/openemr/openemr/
(see there for more details)

## Tags

See the https://hub.docker.com/r/openemr/openemr/ page for documentation of tags and their current aliases.

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
    image: mariadb:10.4
    command: ['mysqld','--character-set-server=utf8']
    volumes:
    - databasevolume:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: root
  openemr:
    restart: always
    image: openemr/openemr:5.0.3
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
[![Try it!](https://github.com/play-with-docker/stacks/raw/cff22438cb4195ace27f9b15784bbb497047afa7/assets/images/button.png)](http://play-with-docker.com/?stack=https://gist.githubusercontent.com/bradymiller/0fcd186130c4ba8ebeb2a7f9a2fc7c81/raw/4208f6f6deb7ed4c59f3279760cf069d070cbb88/openemr-503-docker-example-docker-compose.yml)

## Environment Variables

See the https://hub.docker.com/r/openemr/openemr/ page for documentation of environment variables.

## Where to get help?

For general knowledge, our [wiki](http://www.open-emr.org/wiki) is a repository of helpful information. The [forums](https://community.open-emr.org/) are a great source for assistance and news about emerging features. We also have a [chat](https://chat.open-emr.org/) system for real-time advice and to coordinate our development efforts.

## How can I contribute?

The OpenEMR community is a vibrant and active group, and people from any background can contribute meaningfully, whether they are optimizing our DB calls, or they're doing translations to their native tongue. Feel free to reach out to us at via [chat](https://chat.open-emr.org/)!
