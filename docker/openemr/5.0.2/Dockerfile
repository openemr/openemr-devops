FROM alpine:3.10

#Install dependencies
RUN apk --no-cache upgrade
RUN apk add --no-cache \
    apache2 apache2-ssl git php7 php7-tokenizer php7-ctype php7-session php7-apache2 \
    php7-json php7-pdo php7-pdo_mysql php7-curl php7-ldap php7-openssl php7-iconv \
    php7-xml php7-xsl php7-gd php7-zip php7-soap php7-mbstring php7-zlib \
    php7-mysqli php7-sockets php7-xmlreader php7-redis php7-simplexml php7-xmlwriter php7-phar php7-fileinfo \
    php7-sodium php7-calendar \
    perl mysql-client tar curl imagemagick nodejs nodejs-npm \
    python openssl py-pip openssl-dev dcron \
    shadow
# Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
RUN usermod -u 1000 apache
# Install composer for openemr package building
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer
#clone openemr
RUN apk add --no-cache git build-base libffi-dev python-dev \
    && git clone https://github.com/openemr/openemr.git --branch rel-502 --depth 1 \
    && rm -rf openemr/.git \
    && cd openemr \
    && composer install \
    && npm install --unsafe-perm \
    && npm run build \
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
    && git clone https://github.com/letsencrypt/letsencrypt --branch 0.35.x --depth 1 /opt/certbot \
    && pip install --upgrade pip \
    && pip install -e /opt/certbot/acme -e /opt/certbot \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
    && apk del --no-cache git build-base libffi-dev python-dev
WORKDIR /var/www/localhost/htdocs/openemr
VOLUME [ "/etc/letsencrypt/", "/etc/ssl" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php7/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY run_openemr.sh autoconfig.sh auto_configure.php /var/www/localhost/htdocs/openemr/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh /root/
RUN chmod 500 run_openemr.sh autoconfig.sh /root/unlock_admin.sh \
    && chmod 000 auto_configure.php /root/unlock_admin.php
#bring in pieces used for automatic upgrade process
COPY upgrade/docker-version \
     upgrade/fsupgrade-1.sh \
     /root/
RUN chmod 500 \
    /root/fsupgrade-1.sh
#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2
#go
CMD [ "./run_openemr.sh" ]

EXPOSE 80 443
