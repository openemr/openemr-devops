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
#    - TODO: xdebug options should be given here
#    - EASY_DEV_MODE with value of 'yes' prevents issues with permissions when mounting volumes
#    - EASY_DEV_MODE_NEW with value of 'yes' expands EASY_DEV_MODE by not requiring downloading
#      code from github (uses local repo).
#    - INSANE_DEV_MODE with value of 'yes' is to support devtools in insane dev environment

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

    if [ "$DEMO_MODE" == "standard" ]; then
        demoData
    fi

    if [ "$SQL_DATA_DRIVE" != "" ]; then
        sqlDataDrive
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
    mkdir -p /var/www/localhost/htdocs/openemr/sites/default
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

# this is the primary flex orchestration block
if [ -f /var/www/localhost/htdocs/auto_configure.php ] &&
   [ "$EMPTY" != "yes" ] &&
   [ "$EASY_DEV_MODE_NEW" != "yes" ]; then
    echo "Configuring a new flex openemr docker"
    if [ "$FLEX_REPOSITORY" == "" ]; then
        echo "Missing FLEX_REPOSITORY environment setting, so using https://github.com/openemr/openemr.git"
        FLEX_REPOSITORY="https://github.com/openemr/openemr.git"
    fi
    if [ "$FLEX_REPOSITORY_BRANCH" == "" ] &&
       [ "$FLEX_REPOSITORY_TAG" == "" ]; then
        echo "Missing FLEX_REPOSITORY_BRANCH or FLEX_REPOSITORY_TAG environment setting, so using FLEX_REPOSITORY_BRANCH setting of master"
        FLEX_REPOSITORY_BRANCH="master"
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
    if [ ! -f /etc/docker-leader ] &&
       [ "$SWARM_MODE" == "yes" ]; then
        # non-leader is building so remove the openemr/sites directory to avoid breaking anything in leader's build
        rm -fr openemr/sites
    fi
    rsync --ignore-existing --recursive --links --exclude .git openemr /var/www/localhost/htdocs/
    rm -fr openemr
    cd /var/www/localhost/htdocs/
fi

if [ "$EASY_DEV_MODE_NEW" == "yes" ]; then
    # trickery for the easy dev environment
    rsync --ignore-existing --recursive --links --exclude .git /openemr /var/www/localhost/htdocs/
fi

if [ -f /var/www/localhost/htdocs/auto_configure.php ] &&
   [[ ! -d /var/www/localhost/htdocs/openemr/vendor || \( -d /var/www/localhost/htdocs/openemr/vendor &&  -z "$(ls -A /var/www/localhost/htdocs/openemr/vendor)" \) ]]  &&
   [ "$FORCE_NO_BUILD_MODE" != "yes" ]; then
    cd /var/www/localhost/htdocs/openemr

    # if there is a raw github composer token supplied, then try to use it
    if [ "$GITHUB_COMPOSER_TOKEN" != "" ]; then
        echo "trying raw github composer token"
        githubTokenRateLimitRequest=`curl -H "Authorization: token $GITHUB_COMPOSER_TOKEN" https://api.github.com/rate_limit`
        githubTokenRateLimit=`echo $githubTokenRateLimitRequest | jq '.rate.remaining'`
        githubTokenRateLimitMessage=`echo $githubTokenRateLimitRequest | jq '.message'`
        echo "Number of github api requests remaining is $githubTokenRateLimit";
        echo "Message received from api request is \"$githubTokenRateLimitMessage\"";
        if [ "$githubTokenRateLimit" -gt 100 ]; then
            if `composer config --global --auth github-oauth.github.com "$GITHUB_COMPOSER_TOKEN"`; then
                echo "raw github composer token worked"
                rawToken="pass"
            else
                echo "raw github composer token did not work"
            fi
        else
            if [ "$githubTokenRateLimitMessage" == "\"Bad credentials\"" ]; then
                echo "raw github composer token is bad, so did not work"
            else
                echo "raw github composer token rate limit is now < 100, so did not work"
            fi
        fi
    fi
    # if there is no raw github composer token supplied or it was invalid, try a base64 encoded one (if it was supplied)
    if [ "$GITHUB_COMPOSER_TOKEN_ENCODED" != "" ]; then
        if [ "$rawToken" != "pass" ]; then
            echo "trying encoded github composer token"
            githubToken=`echo $GITHUB_COMPOSER_TOKEN_ENCODED | base64 -d`
            githubTokenRateLimitRequest=`curl -H "Authorization: token $githubToken" https://api.github.com/rate_limit`
            githubTokenRateLimit=`echo $githubTokenRateLimitRequest | jq '.rate.remaining'`
            githubTokenRateLimitMessage=`echo $githubTokenRateLimitRequest | jq '.message'`
            echo "Number of github api requests remaining is $githubTokenRateLimit";
            echo "Message received from api request is \"$githubTokenRateLimitMessage\"";
            if [ "$githubTokenRateLimit" -gt 100 ]; then
                if `composer config --global --auth github-oauth.github.com "$githubToken"`; then
                    echo "encoded github composer token worked"
                else
                    echo "encoded github composer token did not work"
                fi
            else
                if [ "$githubTokenRateLimitMessage" == "\"Bad credentials\"" ]; then
                    echo "encoded github composer token is bad, so did not work"
                else
                    echo "encoded github composer token rate limit is now < 100, so did not work"
                fi
            fi
        fi
    fi
    # install php dependencies
    if [ "$DEVELOPER_TOOLS" == "yes" ]; then
        composer install
        composer global require "squizlabs/php_codesniffer=3.*"
        # install support for the e2e testing
        apk update
        apk add --no-cache chromium chromium-chromedriver
    else
        composer install --no-dev
    fi

    if [ -f /var/www/localhost/htdocs/openemr/package.json ]; then
        # install frontend dependencies (need unsafe-perm to run as root)
        # IN ALPINE 3.14+, there is an odd permission thing happening where need to give non-root ownership
        #  to several places ('node_modules' and 'public') in flex environment that npm is accessing via:
        #    'chown -R apache:1000 node_modules'
        #    'chown -R apache:1000 ccdaservice/node_modules'
        #    'chown -R apache:1000 public'
        # WILL KEEP TRYING TO REMOVE THESE LINES IN THE FUTURE SINCE APPEARS TO LIKELY BE A FLEETING NPM BUG WITH --unsafe-perm SETTING
        #  should be ready to remove then the following npm error no long shows up on the build:
        #    "ERR! warning: unable to access '/root/.config/git/attributes': Permission denied"
        if [ -d node_modules ]; then
            chown -R apache:1000 node_modules
        fi
        if [ -d ccdaservice/node_modules ]; then
            chown -R apache:1000 ccdaservice/node_modules
        fi
        if [ -d public ]; then
            chown -R apache:1000 public
        fi
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

if [ -f /etc/docker-leader ] ||
   [ "$SWARM_MODE" != "yes" ]; then
    if [ -f /var/www/localhost/htdocs/auto_configure.php ] &&
       [ "$EASY_DEV_MODE" != "yes" ]; then
        chmod 666 /var/www/localhost/htdocs/openemr/sites/default/sqlconf.php
    fi
fi

if [ -f /var/www/localhost/htdocs/auto_configure.php ]; then
    chown -R apache /var/www/localhost/htdocs/openemr/
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
fi

if 
   [ "$AUTHORITY" == "yes" ] &&
   [ "$CONFIG" == "1" ] &&
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
        chmod 700 /var/www/localhost/htdocs/openemr.sh
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
        echo "Setup scripts removed, we should be ready to go now!"
        cd /var/www/localhost/htdocs/
    fi
fi

if [ -f /var/www/localhost/htdocs/auto_configure.php ]; then
    if [ "$EASY_DEV_MODE_NEW" == "yes" ] || [ "$INSANE_DEV_MODE" == "yes" ]; then
        # need to copy this script somewhere so the easy/insane dev environment can use it
        cp /var/www/localhost/htdocs/auto_configure.php /root/
        # save couchdb initial data folder to support devtools snapshots
        rsync --recursive --links /couchdb/data /couchdb/original/
    fi
    # trickery to support devtools in insane dev environment (note the easy dev does this with a shared volume)
    if [ "$INSANE_DEV_MODE" == "yes" ]; then
        mkdir /openemr
        rsync --recursive --links /var/www/localhost/htdocs/openemr/sites /openemr/
    fi
fi

if [ -f /etc/docker-leader ] &&
   [ "$SWARM_MODE" == "yes" ] &&
   [ -f /var/www/localhost/htdocs/auto_configure.php ]; then
    # Set flag that the docker-leader configuration is complete
    touch /var/www/localhost/htdocs/openemr/sites/default/docker-completed
fi

# ensure the auto_configure.php script has been removed
rm -f /var/www/localhost/htdocs/auto_configure.php

if [ "$REDIS_SERVER" != "" ] &&
   [ ! -f /etc/php-redis-configured ]; then
    # Variable for $REDIS_SERVER is usually going to be something like 'redis'
    sed -i "s@session.save_handler = files@session.save_handler = redis@" /etc/php81/php.ini
    sed -i "s@;session.save_path = \"/tmp\"@session.save_path = \"tcp://$REDIS_SERVER:6379\"@" /etc/php81/php.ini
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
