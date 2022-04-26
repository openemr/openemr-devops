FROM alpine:3.15

#Install dependencies and fix issue in apache
RUN apk --no-cache upgrade
RUN apk add --no-cache \
    apache2 apache2-ssl apache2-utils git php8 php8-tokenizer php8-ctype php8-session php8-apache2 \
    php8-json php8-pdo php8-pdo_mysql php8-curl php8-ldap php8-openssl php8-iconv \
    php8-xml php8-xsl php8-gd php8-zip php8-soap php8-mbstring php8-zlib \
    php8-mysqli php8-sockets php8-xmlreader php8-redis php8-simplexml php8-xmlwriter php8-phar php8-fileinfo \
    php8-sodium php8-calendar php8-intl \
    perl mysql-client tar curl imagemagick nodejs npm \
    python2 python3 openssl py-pip openssl-dev dcron \
    rsync shadow ncurses \
    && sed -i 's/^Listen 80$/Listen 0.0.0.0:80/' /etc/apache2/httpd.conf
# Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
RUN usermod -u 1000 apache

#BELOW LINE NEEDED TO SUPPORT PHP8 ON ALPINE 3.13+; SHOULD BE ABLE TO REMOVE THIS IN FUTURE ALPINE VERSIONS
RUN cp /usr/bin/php8 /usr/bin/php
# Install composer for openemr package building
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer

RUN apk add --no-cache git build-base libffi-dev python3-dev cargo \
    && git clone https://github.com/openemr/openemr.git --branch rel-610 --depth 1 \
    && rm -rf openemr/.git \
    && cd openemr \
    && composer install --no-dev \
    && npm install --unsafe-perm \
    && npm run build \
    && cd ccdaservice \
    && npm install --unsafe-perm \
    && cd ../ \
    && composer global require phing/phing \
    && /root/.composer/vendor/bin/phing vendor-clean \
    && /root/.composer/vendor/bin/phing assets-clean \
    && composer global remove phing/phing \
    && composer dump-autoload -o \
    && composer clearcache \
    && npm cache clear --force \
    && rm -fr node_modules \
    && cd ../ \
    && chmod 666 openemr/sites/default/sqlconf.php \
    && chown -R apache openemr/ \
    && mv openemr /var/www/localhost/htdocs/ \
    && git clone https://github.com/letsencrypt/letsencrypt --depth 1 /opt/certbot \
    && pip install --upgrade pip \
    && pip install -e /opt/certbot/acme -e /opt/certbot/certbot \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
    && apk del --no-cache git build-base libffi-dev python3-dev cargo \
    && sed -i 's/^ *CustomLog/#CustomLog/' /etc/apache2/httpd.conf \
    && sed -i 's/^ *ErrorLog/#ErrorLog/' /etc/apache2/httpd.conf \
    && sed -i 's/^ *CustomLog/#CustomLog/' /etc/apache2/conf.d/ssl.conf \
    && sed -i 's/^ *TransferLog/#TransferLog/' /etc/apache2/conf.d/ssl.conf
    
WORKDIR /var/www/localhost/htdocs/openemr
VOLUME [ "/etc/letsencrypt/", "/etc/ssl" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php8/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY openemr.sh ssl.sh xdebug.sh auto_configure.php /var/www/localhost/htdocs/openemr/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh /root/
RUN chmod 500 openemr.sh ssl.sh xdebug.sh /root/unlock_admin.sh \
    && chmod 000 auto_configure.php /root/unlock_admin.php
#bring in pieces used for automatic upgrade process
COPY upgrade/docker-version \
     upgrade/fsupgrade-1.sh \
     upgrade/fsupgrade-2.sh \
     upgrade/fsupgrade-3.sh \
     /root/
RUN chmod 500 \
    /root/fsupgrade-1.sh \
    /root/fsupgrade-2.sh \
    /root/fsupgrade-3.sh
#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2
#Copy dev tools library to root
COPY utilities/devtoolsLibrary.source /root/
#Ensure swarm/orchestration pieces are available if needed
RUN mkdir /swarm-pieces \
    && rsync --owner --group --perms --delete --recursive --links /etc/ssl /swarm-pieces/ \
    && rsync --owner --group --perms --delete --recursive --links /var/www/localhost/htdocs/openemr/sites /swarm-pieces/
#go
CMD [ "./openemr.sh" ]

EXPOSE 80 443
