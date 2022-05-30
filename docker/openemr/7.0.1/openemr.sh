#!/bin/sh
# Allows customization of openemr credentials, preventing the need for manual setup
#  (Note can force a manual setup by setting MANUAL_SETUP to 'yes')
#  - Required settings for auto installation are MYSQL_HOST and MYSQL_ROOT_PASS
#  -  (note that can force MYSQL_ROOT_PASS to be empty by passing as 'BLANK' variable)
#  - Optional settings for auto installation are:
#    - Setting db parameters MYSQL_USER, MYSQL_PASS, MYSQL_DATABASE
#    - Setting openemr parameters OE_USER, OE_PASS
# TODO: xdebug options should be given here
set -e

source /root/devtoolsLibrary.source

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
    prepareVariables

    chmod -R 600 .
    php auto_configure.php -f ${CONFIGURATION} || return 1

    echo "OpenEMR configured."
    CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
    if [ "$CONFIG" == "0" ]; then
        echo "Error in auto-config. Configuration failed."
        exit 2
    fi

    setGlobalSettings
}

# AUTHORITY is the right to change OpenEMR's configured state
# - true for singletons, swarm leaders, and the Kubernetes startup job
# - false for swarm members and Kubernetes workers
# OPERATOR is the right to launch Apache and serve OpenEMR
# - true for singletons, swarm members (leader or otherwise), and Kubernetes workers
# - false for the Kubernetes startup job and manual image runs
AUTHORITY=yes
OPERATOR=yes
if [ "$K8S" == "admin" ]; then
    OPERATOR=no
elif [ "$K8S" == "worker" ]; then
    AUTHORITY=no
fi
if [ "$SWARM_MODE" == "yes" ]; then
    # atomically test for leadership
    set -o noclobber
    { > /etc/docker-leader ; } &> /dev/null || AUTHORITY=no
    set +o noclobber
    
    if [ "$AUTHORITY" == "yes" ]; then       
        touch /var/www/localhost/htdocs/openemr/sites/default/docker-initiated                  
    fi
fi

if [ "$SWARM_MODE" == "yes" ]; then
    # Check if the shared volumes have been emptied out (persistent volumes in
    # kubernetes seems to do this). If they have been emptied, then restore them.
    if [ ! -f /etc/ssl/openssl.cnf ]; then
        # Restore the emptied /etc/ssl directory
        echo "Restoring empty /etc/ssl directory."
        rsync --owner --group --perms --recursive --links /swarm-pieces/ssl /etc/
    fi
    if [ ! -d /var/www/localhost/htdocs/openemr/sites/default ]; then
        # Restore the emptied /var/www/localhost/htdocs/openemr/sites directory
        echo "Restoring empty /var/www/localhost/htdocs/openemr/sites directory."
        rsync --owner --group --perms --recursive --links /swarm-pieces/sites /var/www/localhost/htdocs/openemr/
    fi

    if [ "$AUTHORITY" == "no" ] &&
       [ ! -f /var/www/localhost/htdocs/openemr/sites/default/docker-completed ]; then
        while swarm_wait; do
            echo "Waiting for the docker-leader to finish configuration before proceeding."
            sleep 10;
        done
    fi
fi

if [ "$AUTHORITY" == "yes" ]; then
    sh ssl.sh
fi

UPGRADE_YES=false;
if [ "$AUTHORITY" == "yes" ]; then
    # Figure out if need to do upgrade
    if [ -f /root/docker-version ]; then
        DOCKER_VERSION_ROOT=$(cat /root/docker-version)
    else
        DOCKER_VERSION_ROOT=0
    fi
    if [ -f /var/www/localhost/htdocs/openemr/docker-version ]; then
        DOCKER_VERSION_CODE=$(cat /var/www/localhost/htdocs/openemr/docker-version)
    else
        DOCKER_VERSION_CODE=0
    fi
    if [ -f /var/www/localhost/htdocs/openemr/sites/default/docker-version ]; then
        DOCKER_VERSION_SITES=$(cat /var/www/localhost/htdocs/openemr/sites/default/docker-version)
    else
        DOCKER_VERSION_SITES=0
    fi

    # Only perform upgrade if the sites dir is shared and not entire openemr directory
    if [ "$DOCKER_VERSION_ROOT" == "$DOCKER_VERSION_CODE" ] &&
       [ "$DOCKER_VERSION_ROOT" -gt "$DOCKER_VERSION_SITES" ]; then
        echo "Plan to try an upgrade from $DOCKER_VERSION_SITES to $DOCKER_VERSION_ROOT"
        UPGRADE_YES=true;
    fi
fi

CONFIG=$(php -r "require_once('/var/www/localhost/htdocs/openemr/sites/default/sqlconf.php'); echo \$config;")
if [ "$AUTHORITY" == "no" ] &&
    [ "$CONFIG" == "0" ]; then
    echo "Critical failure! An OpenEMR worker is trying to run on a missing configuration."
    echo " - Is this due to a Kubernetes grant hiccup?"
    echo "The worker will now terminate."
    exit 1
fi

if [ "$AUTHORITY" == "yes" ]; then
    if [ "$CONFIG" == "0" ] &&
       [ "$MYSQL_HOST" != "" ] &&
       [ "$MYSQL_ROOT_PASS" != "" ] &&
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
fi

if 
   [ "$AUTHORITY" == "yes" ] &&
   [ "$CONFIG" == "1" ] &&
   [ "$MANUAL_SETUP" != "yes" ]; then
    # OpenEMR has been configured

    if $UPGRADE_YES; then
        # Need to do the upgrade
        echo "Attempting upgrade"
        c=$DOCKER_VERSION_SITES
        while [ "$c" -le "$DOCKER_VERSION_ROOT" ]; do
            if [ "$c" -gt "$DOCKER_VERSION_SITES" ] ; then
                echo "Start: Processing fsupgrade-$c.sh upgrade script"
                sh /root/fsupgrade-$c.sh
                echo "Completed: Processing fsupgrade-$c.sh upgrade script"
            fi
            c=$(( c + 1 ))
        done
        echo -n $DOCKER_VERSION_ROOT > /var/www/localhost/htdocs/openemr/sites/default/docker-version
        echo "Completed upgrade"
    fi

    if [ -f auto_configure.php ]; then
        # This section only runs once after above configuration since auto_configure.php gets removed after this script
        echo "Setting user 'www' as owner of openemr/ and setting file/dir permissions to 400/500"
        #set all directories to 500
        find . -type d -print0 | xargs -0 chmod 500
        #set all file access to 400
        find . -type f -print0 | xargs -0 chmod 400

        echo "Default file permissions and ownership set, allowing writing to specific directories"
        chmod 700 openemr.sh
        # Set file and directory permissions
        find sites/default/documents -type d -print0 | xargs -0 chmod 700
        find sites/default/documents -type f -print0 | xargs -0 chmod 700

        echo "Removing remaining setup scripts"
        #remove all setup scripts
        rm -f admin.php
        rm -f acl_upgrade.php
        rm -f setup.php
        rm -f sql_patch.php
        rm -f sql_upgrade.php
        rm -f ippf_upgrade.php
        rm -f auto_configure.php
        echo "Setup scripts removed, we should be ready to go now!"
    fi
fi

if [ "$AUTHORITY" == "yes" ] &&
   [ "$SWARM_MODE" == "yes" ]; then
    # Set flag that the docker-leader configuration is complete
    touch /var/www/localhost/htdocs/openemr/sites/default/docker-completed
fi

if [ "$REDIS_SERVER" != "" ] &&
   [ ! -f /etc/php-redis-configured ]; then
    # Variable for $REDIS_SERVER is usually going to be something like 'redis'
    sed -i "s@session.save_handler = files@session.save_handler = redis@" /etc/php8/php.ini
    sed -i "s@;session.save_path = \"/tmp\"@session.save_path = \"tcp://$REDIS_SERVER:6379\"@" /etc/php8/php.ini
    # Ensure only configure this one time
    touch /etc/php-redis-configured
fi

if [ "$XDEBUG_IDE_KEY" != "" ] ||
   [ "$XDEBUG_ON" == 1 ]; then
   sh xdebug.sh
fi

echo ""
echo "Love OpenEMR? You can now support the project via the open collective:"
echo " > https://opencollective.com/openemr/donate"
echo ""

if [ "$OPERATOR" == "yes" ]; then
    echo "Starting apache!"
    /usr/sbin/httpd -D FOREGROUND
else
    echo "OpenEMR configuration tasks have concluded."
    exit 0
fi