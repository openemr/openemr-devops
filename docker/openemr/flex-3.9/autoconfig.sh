#!/bin/sh
# Allows customization of openemr credentials, preventing the need for manual setup
#  (Note can force a manual setup by setting MANUAL_SETUP to 'yes')
#  - Required settings for this special flex openemr docker are FLEX_REPOSITORY
#    and (FLEX_REPOSITORY_BRANCH or FLEX_REPOSITORY_TAG). FLEX_REPOSITORY is the
#    public git repository holding the openemr version that will be used. And
#    FLEX_REPOSITORY_BRANCH or FLEX_REPOSITORY_TAG represent the branch or tag
#    to use in this git repository, respectively.
#  - Required settings for auto installation are MYSQL_HOST and MYSQL_ROOT_PASS
#  -  (note that can force MYSQL_ROOT_PASS to be empty by passing as 'BLANK' variable)
#  - Optional settings for auto installation are:
#    - Setting db parameters MYSQL_USER, MYSQL_PASS, MYSQL_DATABASE
#    - Setting openemr parameters OE_USER, OE_PASS
#    - EASY_DEV_MODE with value of 'yes' prevents issues with permissions when mounting volumes
set -e

swarm_wait() {
    if [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-completed ]; then
        # true
        return 0
    else
        # false
        return 1
    fi
}

auto_setup() {

    CONFIGURATION="server=${MYSQL_HOST} rootpass=${MYSQL_ROOT_PASS} loginhost=%"
    if [ "$MYSQL_ROOT_USER" != "" ]; then
        CONFIGURATION="${CONFIGURATION} root=${MYSQL_ROOT_USER}"
    fi
    if [ "$MYSQL_USER" != "" ]; then
        CONFIGURATION="${CONFIGURATION} login=${MYSQL_USER}"
    fi
    if [ "$MYSQL_PASS" != "" ]; then
        CONFIGURATION="${CONFIGURATION} pass=${MYSQL_PASS}"
    fi
    if [ "$MYSQL_DATABASE" != "" ]; then
        CONFIGURATION="${CONFIGURATION} dbname=${MYSQL_DATABASE}"
    fi
    if [ "$OE_USER" != "" ]; then
        CONFIGURATION="${CONFIGURATION} iuser=${OE_USER}"
    fi
    if [ "$OE_PASS" != "" ]; then
        CONFIGURATION="${CONFIGURATION} iuserpass=${OE_PASS}"
    fi

    if [ "$EASY_DEV_MODE" != "yes" ]; then
        chmod -R 600 /var/www/localhost/htdocs/openemr
    fi
    php /var/www/localhost/htdocs/auto_configure.php -f ${CONFIGURATION} || return 1

    echo "OpenEMR configured."
    CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
    if [ "$CONFIG" == "0" ]; then
        echo "Error in auto-config. Configuration failed."
        exit 2
    fi
}

if [ "$SWARM_MODE" == "yes" ]; then
    # Need to support replication for docker orchestration
    mkdir -p /var/www/localhost/htdocs/openemr/sites/default
    if [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-initiated ]; then
        # This docker instance will be the leader and perform configuration
        touch /var/www/localhost/htdocs/openemr/sites/default/docker-initiated
        touch /etc/docker-leader
    fi

    if [ ! -f /etc/docker-leader ] &&
       [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-completed ]; then
        while swarm_wait; do
            echo "Waiting for the docker-leader to finish configuration before proceeding."
            sleep 10;
        done
    fi
fi

if [ -f /etc/docker-leader ] ||
   [ "$SWARM_MODE" != "yes" ]; then
    # ensure a self-signed cert has been generated and is referenced
    if ! [ -f /etc/ssl/private/selfsigned.key.pem ]; then
        openssl req -x509 -newkey rsa:4096 \
        -keyout /etc/ssl/private/selfsigned.key.pem \
        -out /etc/ssl/certs/selfsigned.cert.pem \
        -days 365 -nodes \
        -subj "/C=xx/ST=x/L=x/O=x/OU=x/CN=localhost"
    fi
    rm -f /etc/ssl/certs/webserver.cert.pem
    rm -f /etc/ssl/private/webserver.key.pem
    ln -s /etc/ssl/certs/selfsigned.cert.pem /etc/ssl/certs/webserver.cert.pem
    ln -s /etc/ssl/private/selfsigned.key.pem /etc/ssl/private/webserver.key.pem

    if [ "$DOMAIN" != "" ]; then
        if [ "$EMAIL" != "" ]; then
            EMAIL="-m $EMAIL"
        else
            echo "WARNING: SETTING AN EMAIL VIA \$EMAIL is HIGHLY RECOMMENDED IN ORDER TO"
            echo "         RECEIVE ALERTS FROM LETSENCRYPT ABOUT YOUR SSL CERTIFICATE."
        fi
        # if a domain has been set, set up LE and target those certs
        if ! [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
            /usr/sbin/httpd -k start
            sleep 2
            certbot certonly --webroot -n -w /var/www/localhost/htdocs/openemr/ -d $DOMAIN $EMAIL --agree-tos
            /usr/sbin/httpd -k stop
            echo "1 23  *   *   *   certbot renew -q --post-hook \"httpd -k graceful\"" >> /etc/crontabs/root
        fi

        # run letsencrypt as a daemon and reference the correct cert
        rm -f /etc/ssl/certs/webserver.cert.pem
        rm -f /etc/ssl/private/webserver.key.pem
        ln -s /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/ssl/certs/webserver.cert.pem
        ln -s /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/ssl/private/webserver.key.pem
    fi
fi

if [ -f /etc/docker-leader ] ||
   [ "$SWARM_MODE" != "yes" ]; then
    if [ -f /var/www/localhost/htdocs/auto_configure.php ] &&
       [ "$EMPTY" != "yes" ] ; then
        echo "Configuring a new flex openemr docker"
        if [ "$FLEX_REPOSITORY" == "" ]; then
            echo "Exiting from OpenEMR flex docker since missing required FLEX_REPOSITORY environment setting."
            exit 1
        fi
        if [ "$FLEX_REPOSITORY_BRANCH" == "" ] &&
           [ "$FLEX_REPOSITORY_TAG" == "" ]; then
            echo "Exiting from OpenEMR flex docker since missing required FLEX_REPOSITORY_BRANCH or FLEX_REPOSITORY_TAG environment setting."
            exit 1
        fi

        cd /

        if [ "$FLEX_REPOSITORY_BRANCH" != "" ]; then
            echo "Collecting $FLEX_REPOSITORY_BRANCH branch from $FLEX_REPOSITORY repository"
            git clone "$FLEX_REPOSITORY" --branch "$FLEX_REPOSITORY_BRANCH" --depth 1
        else
            echo "Collecting $FLEX_REPOSITORY_TAG tag from $FLEX_REPOSITORY repository"
            git clone "$FLEX_REPOSITORY"
            cd openemr
            git checkout "$FLEX_REPOSITORY_TAG"
            cd ../
        fi
        if [ -f /etc/docker-leader ] &&
           [ "$SWARM_MODE" == "yes" ]; then
            touch openemr/sites/default/docker-initiated
        fi
        rsync --ignore-existing --recursive --links --exclude .git openemr /var/www/localhost/htdocs/
        rm -fr openemr
        cd /var/www/localhost/htdocs/
    fi

    if [ -f /var/www/localhost/htdocs/auto_configure.php ] &&
       [[ ! -d /var/www/localhost/htdocs/openemr/vendor || \( -d /var/www/localhost/htdocs/openemr/vendor &&  -z "$(ls -A /var/www/localhost/htdocs/openemr/vendor)" \) ]]  &&
       [ "$FORCE_NO_BUILD_MODE" != "yes" ]; then
        cd /var/www/localhost/htdocs/openemr

        # install php dependencies
        composer install

        if [ -f /var/www/localhost/htdocs/openemr/package.json ]; then
            # install frontend dependencies (need unsafe-perm to run as root)
            npm install --unsafe-perm
            # build css
            npm run build
        fi

        if [ -f /var/www/localhost/htdocs/openemr/ccdaservice/package.json ]; then
            # install ccdaservice
            cd /var/www/localhost/htdocs/openemr/ccdaservice
            npm install --unsafe-perm
            cd /var/www/localhost/htdocs/openemr
        fi

        # clean up
        composer global require phing/phing
        /root/.composer/vendor/bin/phing vendor-clean
        /root/.composer/vendor/bin/phing assets-clean
        composer global remove phing/phing

        # optimize
        composer dump-autoload -o

        cd /var/www/localhost/htdocs
    fi

    if [ -f /var/www/localhost/htdocs/auto_configure.php ] &&
       [ "$EASY_DEV_MODE" != "yes" ]; then
        chmod 666 /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
    fi

    if [ -f /var/www/localhost/htdocs/auto_configure.php ]; then
        chown -R apache /var/www/localhost/htdocs/openemr/
    fi

    CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
    if [ "$CONFIG" == "0" ] &&
       [ "$MYSQL_HOST" != "" ] &&
       [ "$MYSQL_ROOT_PASS" != "" ] &&
       [ "$EMPTY" != "yes" ] &&
       [ "$MANUAL_SETUP" != "yes" ]; then

        echo "Running quick setup!"
        while ! auto_setup; do
            echo "Couldn't set up. Any of these reasons could be what's wrong:"
            echo " - You didn't spin up a MySQL container or connect your OpenEMR container to a mysql instance"
            echo " - MySQL is still starting up and wasn't ready for connection yet"
            echo " - The Mysql credentials were incorrect"
            sleep 1;
        done
        echo "Setup Complete!"
    fi

    if [ "$CONFIG" == "1" ] &&
       [ "$MANUAL_SETUP" != "yes" ] &&
       [ "$EASY_DEV_MODE" != "yes" ] &&
       [ "$EMPTY" != "yes" ]; then
        # OpenEMR has been configured
        if [ -f /var/www/localhost/htdocs/auto_configure.php ]; then
            cd /var/www/localhost/htdocs/openemr/
            # This section only runs once after above configuration since auto_configure.php gets removed after this script
            echo "Setting user 'www' as owner of openemr/ and setting file/dir permissions to 400/500"
            #set all directories to 500
            find . -type d -print0 | xargs -0 chmod 500
            #set all file access to 400
            find . -type f -print0 | xargs -0 chmod 400

            echo "Default file permissions and ownership set, allowing writing to specific directories"
            chmod 700 /var/www/localhost/htdocs/run_openemr.sh
            # Set file and directory permissions
            find sites/default/documents -type d -print0 | xargs -0 chmod 700
            find sites/default/documents -type f -print0 | xargs -0 chmod 700

            echo "Removing remaining setup scripts"
            #remove all setup scripts
            rm -f admin.php
            rm -f acl_setup.php
            rm -f acl_upgrade.php
            rm -f setup.php
            rm -f sql_patch.php
            rm -f sql_upgrade.php
            rm -f ippf_upgrade.php
            rm -f gacl/setup.php
            echo "Setup scripts removed, we should be ready to go now!"
            cd /var/www/localhost/htdocs/
        fi
    fi

    # ensure the auto_configure.php script has been removed
    rm -f /var/www/localhost/htdocs/auto_configure.php
fi

if [ -f /etc/docker-leader ] &&
   [ "$SWARM_MODE" == "yes" ]; then
    # Set flag that the docker-leader configuration is complete
    touch /var/www/localhost/htdocs/openemr/sites/default/docker-completed
fi

if [ "$REDIS_SERVER" != "" ] &&
   [ ! -f /etc/php-redis-configured ]; then
    # Variable for $REDIS_SERVER is usually going to be something like 'redis'
    sed -i "s@session.save_handler = files@session.save_handler = redis@" /etc/php7/php.ini
    sed -i "s@;session.save_path = \"/tmp\"@session.save_path = \"tcp://$REDIS_SERVER:6379\"@" /etc/php7/php.ini
    # Ensure only configure this one time
    touch /etc/php-redis-configured
fi
