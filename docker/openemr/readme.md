# OpenEMR Official Docker Image

This is the official OpenEMR docker image!

## Tags

To-do... (currently all we've got is v5.0.0, tagged as `latest`)

## How can I just spin up OpenEMR?

The easiest way is to use `docker-compose`. The following `docker-compose.yml` file is a good example:
```yaml
# Use root/example as user/password credentials
version: '3.1'
services:
    db:
        image: mysql
        environment:
            MYSQL_ROOT_PASSWORD: root
    openemr:
        image: openemr
        ports:
        - 80:80
        volumes:
        - logvolume01:/var/log
        - sitevolume:/var/www/localhost/htdocs/openemr/sites/default
        environment:
            MYSQL_HOST: db
            MYSQL_ROOT_PASS: root
            MYSQL_USER: root
            MYSQL_PASS: root
            OE_USER: admin
            OE_PASS: admin
        links:
        - db
```
[![Try it!](https://github.com/play-with-docker/stacks/raw/cff22438cb4195ace27f9b15784bbb497047afa7/assets/images/button.png)](http://play-with-docker.com/?stack=https://raw.githubusercontent.com/openemr/openemr-devops/master/docker/openemr/docker-compose-example.yml)

## Environment Variables

Setting `MYSQL_USER`, `MYSQL_ROOT_PASS`, `MYSQL_PASS`, `MYSQL_HOST`, `OE_USER`, and `OE_PASS` will do the first-time setup process without manual intervention, setting the database connection using the `MYSQL_*` variables and adding an admin user to OpenEMR using `OE_USER` and `OE_PASS`. 

## Where to get help?

For general knowledge, our [wiki](http://www.open-emr.org/wiki) is a repository of helpful information. The [forums](https://community.open-emr.org/) are a great source for assistance and news about emerging features. We also have a [chat](https://chat.open-emr.org/) system for real-time advice and to coordinate our development efforts.

## How can I contribute?

The OpenEMR community is a vibrant and active group, and people from any background can contribute meaningfully, whether they are optimizing our DB calls, or they're doing translations to their native tongue. Feel free to reach out to us at via [chat](https://chat.open-emr.org/)!