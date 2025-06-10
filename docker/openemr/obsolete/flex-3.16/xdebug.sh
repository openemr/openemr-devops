#!/bin/sh

set -e

if [ ! "$XDEBUG_IDE_KEY" != "" ] &&
   [ ! "$XDEBUG_ON" == 1 ]; then
   echo bad context for xdebug.sh launch
   exit 1
fi

if [ ! -f /etc/php-xdebug-configured ]; then
    # install xdebug library
    apk update
    apk add --no-cache php81-pecl-xdebug

    # set up xdebug in php.ini
    echo "; start xdebug configuration" >> /etc/php81/php.ini
    echo "zend_extension=/usr/lib/php81/modules/xdebug.so" >> /etc/php81/php.ini
    echo "xdebug.output_dir=/tmp" >> /etc/php81/php.ini
    echo "xdebug.start_with_request=trigger" >> /etc/php81/php.ini
    echo "xdebug.remote_handler=dbgp" >> /etc/php81/php.ini
    echo "xdebug.log=/tmp/xdebug.log" >> /etc/php81/php.ini
    echo "xdebug.discover_client_host=1" >> /etc/php81/php.ini
    if [ "$XDEBUG_PROFILER_ON" == 1 ]; then
        # set up xdebug profiler
        echo "xdebug.mode=debug,profile" >> /etc/php81/php.ini
        echo "xdebug.profiler_output_name=cachegrind.out.%s" >> /etc/php81/php.ini
    else
        echo "xdebug.mode=debug" >> /etc/php81/php.ini
    fi
    if [ "$XDEBUG_CLIENT_PORT" != "" ]; then
        # manually set up host port, if set
        echo "xdebug.client_port=${XDEBUG_CLIENT_PORT}" >> /etc/php81/php.ini
    else
        echo "xdebug.client_port=9003" >> /etc/php81/php.ini
    fi
    if [ "$XDEBUG_CLIENT_HOST" != "" ]; then
        # manually set up host, if set
        echo "xdebug.client_host=${XDEBUG_CLIENT_HOST}" >> /etc/php81/php.ini
    fi
    if [ "$XDEBUG_IDE_KEY" != "" ]; then
        # set up ide key, if set
        echo "xdebug.idekey=${XDEBUG_IDE_KEY}" >> /etc/php81/php.ini
    fi
    echo "; end xdebug configuration" >> /etc/php81/php.ini

    # Ensure only configure this one time
    touch /etc/php-xdebug-configured
fi

# to prevent the 'Xdebug: [Log Files] File '/tmp/xdebug.log' could not be opened.' messages
#  (need to keep doing this since /tmp may be cleared)
if [ ! -f /tmp/xdebug.log ]; then
    touch /tmp/xdebug.log;
fi
chmod 666 /tmp/xdebug.log;
