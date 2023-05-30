#!/bin/sh

set -e

if [ ! "$OPCACHE_ON" == 1 ]; then
   echo bad context for opcache.sh launch
   exit 1
fi

if [ ! -f /etc/php-opcache-configured ]; then
    # install opcache library
    apk update
    apk add --no-cache php81-opcache 

    # set up xdebug in php.ini
    echo "; start opcache configuration" >> /etc/php81/php.ini
    echo "zend_extension=opcache" >> /etc/php81/php.ini
    echo "opcache.enable=1" >> /etc/php81/php.ini
    echo "opcache.enable_cli=0" >> /etc/php81/php.ini
    echo "opcache.memory_consumption=128" >> /etc/php81/php.ini
    echo "opcache.max_accelerated_files=100000" >> /etc/php81/php.ini
    echo "opcache.max_wasted_percentage=5" >> /etc/php81/php.ini
    echo "opcache.save_comments=1" >> /etc/php81/php.ini
    if [ ! "$OPCACHE_ON" == 1 ]; then
	   echo bad context for opcache.sh launch
	   exit 1
	fi
    if [ ! "$XDEBUG_IDE_KEY" != "" ] &&
	   [ ! "$XDEBUG_ON" == 1 ]; then
    	   echo "opcache.jit_buffer_size=100M" >> /etc/php81/php.ini
           echo "opcache.jit=tracing" >> /etc/php81/php.ini
    fi

    # Ensure only configure this one time
    touch /etc/php-opcache-configured
fi
