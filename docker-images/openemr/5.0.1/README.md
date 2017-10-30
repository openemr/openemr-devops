# OpenEMR Official Docker Image

The docker image is maintained at https://hub.docker.com/r/openemr/openemr/
(see there for more details)

## Tags

Tags and their current aliases are shown below:

 - `5.0.0`: latest, stable
 - `5.0.1`: next, dev

It is recommended to specify a version number in production, to ensure your build process pulls what you expect it to.

## How can I just spin up OpenEMR?

*You **need** to run an instance of mysql/mariadb as well and connect it to this container! You can then either use auto-setup with environment variables (see below) or you can manually set up, telling the server where to find the db.* The easiest way is to use `docker-compose`. The following `docker-compose.yml` file is a good example:
```yaml
# Use admin/pass as user/password credentials
version: '3.1'
services:
  mysql:
    restart: always
    image: mysql
    command: ['mysqld','--character-set-server=utf8']
    environment:
      MYSQL_ROOT_PASSWORD: root
  openemr:
    restart: always
    image: openemr/openemr
    ports:
    - 80:80
    - 443:443
    volumes:
    - logvolume01:/var/log
    - sitevolume:/var/www/localhost/htdocs/openemr/sites/default
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: root
      MYSQL_USER: root
      MYSQL_PASS: root
      OE_USER: admin
      OE_PASS: pass
    links:
    - mysql
volumes:
  logvolume01: {}
  sitevolume: {}
```
[![Try it!](https://github.com/play-with-docker/stacks/raw/cff22438cb4195ace27f9b15784bbb497047afa7/assets/images/button.png)](http://play-with-docker.com/?stack=https://gist.githubusercontent.com/TheToolbox/457811557ac45c4475b97ee0f346c9df/raw/288c1e67946148524b26f364208ed929e67e88bb/docker-compose.yml)

## Environment Variables

Required environment settings for auto installation are `MYSQL_HOST` and `MYSQL_ROOT_PASS` (Note that can force `MYSQL_ROOT_PASS` to be empty by passing as 'BLANK' variable).

Optional settings for the auto installation include database parameters `MYSQL_ROOT_USER`, `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_DATABASE`, and openemr parameters `OE_USER`, `OE_PASS`.

Can override auto installation and force manual installation by setting `MANUAL_SETUP` environment setting to 'yes'.

Can use both port 80 and 443. Port 80 is standard http. Port 443 is https/ssl and uses a self-signed certificate by default; if assign the `DOMAIN` and `EMAIL`(optional) environment settings, then it will set up and maintain certificates via letsencrypt.

## Where to get help?

For general knowledge, our [wiki](http://www.open-emr.org/wiki) is a repository of helpful information. The [forums](https://community.open-emr.org/) are a great source for assistance and news about emerging features. We also have a [chat](https://chat.open-emr.org/) system for real-time advice and to coordinate our development efforts.

## How can I contribute?

The OpenEMR community is a vibrant and active group, and people from any background can contribute meaningfully, whether they are optimizing our DB calls, or they're doing translations to their native tongue. Feel free to reach out to us at via [chat](https://chat.open-emr.org/)!