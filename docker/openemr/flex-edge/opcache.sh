#!/bin/sh

set -e

if [ ! "$OPCACHE_ON" == 1 ]; then
   echo bad context for opcache.sh launch
   exit 1
fi

if [ ! -f /etc/php-opcache-configured ]; then
    # install opcache library
    apk update
    apk add --no-cache php82-opcache 

    # set up xdebug in php.ini
    echo "; start opcache configuration" >> /etc/php82/php.ini
    echo "zend_extension=opcache" >> /etc/php82/php.ini
    echo "opcache.enable=1" >> /etc/php82/php.ini
    echo "opcache.enable_cli=0" >> /etc/php82/php.ini
    echo "opcache.memory_consumption=128" >> /etc/php82/php.ini
    echo "opcache.max_accelerated_files=100000" >> /etc/php82/php.ini
    echo "opcache.max_wasted_percentage=5" >> /etc/php82/php.ini
    echo "opcache.save_comments=1" >> /etc/php82/php.ini
    echo "opcache.jit_buffer_size=100M" >> /etc/php82/php.ini
    echo "opcache.jit=tracing" >> /etc/php82/php.ini

    # Ensure only configure this one time
    touch /etc/php-opcache-configured
fi
