# OpenEMR Official Docker Image

The docker image is maintained at https://hub.docker.com/r/openemr/openemr/
(see there for more details)

## Tags

Tags and their current aliases are shown below:

 - `flex`: (special development docker that can use OpenEMR version from any public git repository)
 - `5.0.2`: next
 - `5.0.1`: latest
 - `5.0.0`

## How can I just spin up OpenEMR?

*You **need** to run an instance of mysql/mariadb as well and connect it to this container! You can then either use auto-setup with environment variables (see below) or you can manually set up, telling the server where to find the db.* The easiest way is to use `docker-compose`. The following `docker-compose.yml` file is a good example:
```yaml
# Use admin/pass as user/password credentials to login to openemr (from OE_USER and OE_PASS below)
# MYSQL_HOST and MYSQL_ROOT_PASS are required for openemr
# FLEX_REPOSITORY and (FLEX_REPOSITORY_BRANCH or FLEX_REPOSITORY_TAG) are required for flex openemr
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
    image: openemr/openemr:flex
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
      FLEX_REPOSITORY: https://github.com/openemr/openemr.git
      FLEX_REPOSITORY_BRANCH: master
    depends_on:
    - mysql
volumes:
  logvolume01: {}
  sitevolume: {}
  databasevolume: {}
```
[![Try it!](https://github.com/play-with-docker/stacks/raw/cff22438cb4195ace27f9b15784bbb497047afa7/assets/images/button.png)](http://play-with-docker.com/?stack=https://gist.githubusercontent.com/bradymiller/6972c32d0af9dc42b96f2ad7c11f06ef/raw/0549cfacc77cd537fa36568e3db41d8879b395ec/openemr-flex-docker-example-docker-compose.yml)

## Environment Variables
Required environment settings for flex are `FLEX_REPOSITORY` and (`FLEX_REPOSITORY_BRANCH` or `FLEX_REPOSITORY_TAG`). `FLEX_REPOSITORY` is the public git repository holding the openemr version that will be used. And `FLEX_REPOSITORY_BRANCH` or `FLEX_REPOSITORY_TAG` represent the branch or tag to use in this git repository, respectively.

Required environment settings for auto installation are `MYSQL_HOST` and `MYSQL_ROOT_PASS` (Note that can force `MYSQL_ROOT_PASS` to be empty by passing as 'BLANK' variable).

Optional settings for the auto installation include database parameters `MYSQL_ROOT_USER`, `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_DATABASE`, and openemr parameters `OE_USER`, `OE_PASS`.

Can override auto installation and force manual installation by setting `MANUAL_SETUP` environment setting to 'yes'.

Can use both port 80 and 443. Port 80 is standard http. Port 443 is https/ssl and uses a self-signed certificate by default; if assign the `DOMAIN` and `EMAIL`(optional) environment settings, then it will set up and maintain certificates via letsencrypt.

## Where to get help?

For general knowledge, our [wiki](http://www.open-emr.org/wiki) is a repository of helpful information. The [forums](https://community.open-emr.org/) are a great source for assistance and news about emerging features. We also have a [chat](https://chat.open-emr.org/) system for real-time advice and to coordinate our development efforts.

## How can I contribute?

The OpenEMR community is a vibrant and active group, and people from any background can contribute meaningfully, whether they are optimizing our DB calls, or they're doing translations to their native tongue. Feel free to reach out to us at via [chat](https://chat.open-emr.org/)!
