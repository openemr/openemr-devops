FROM alpine:3.13

#Install dependencies and fix issue in apache
RUN apk --no-cache upgrade
RUN apk add --no-cache \
    apache2 apache2-ssl git php7 php7-tokenizer php7-ctype php7-session php7-apache2 \
    php7-json php7-pdo php7-pdo_mysql php7-curl php7-ldap php7-openssl php7-iconv \
    php7-xml php7-xsl php7-gd php7-zip php7-soap php7-mbstring php7-zlib \
    php7-mysqli php7-sockets php7-xmlreader php7-redis perl php7-simplexml php7-xmlwriter php7-phar php7-fileinfo \
    php7-sodium php7-calendar php7-intl \
    mysql-client tar curl imagemagick npm \
    python2 python3 openssl git py-pip openssl-dev dcron \
    rsync shadow jq ncurses \
    && sed -i 's/^Listen 80$/Listen 0.0.0.0:80/' /etc/apache2/httpd.conf
# Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
    RUN usermod -u 1000 apache
#Stuff for developers since this predominantly a developer/tester docker
RUN apk add --no-cache \
    unzip vim nano bash bash-doc bash-completion tree
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer

# Below line is needed to avoid breaking the raspberry pi builds
# TODO - intermittently remove this line to see if the error (failed to fetch
#        https://github.com/rust-lang/crates.io-index... ) has gone away.
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

RUN apk add --no-cache build-base libffi-dev python3-dev cargo \
    && mkdir -p /var/www/localhost/htdocs/openemr/sites \
    && chown -R apache /var/www/localhost/htdocs/openemr \
    && git clone https://github.com/letsencrypt/letsencrypt --depth 1 /opt/certbot \
    && pip install --upgrade pip \
    && pip install -e /opt/certbot/acme -e /opt/certbot/certbot \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
    && apk del --no-cache build-base libffi-dev python3-dev cargo
WORKDIR /var/www/localhost/htdocs
VOLUME [ "/etc/letsencrypt/", "/etc/ssl" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php7/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY run_openemr.sh autoconfig.sh auto_configure.php /var/www/localhost/htdocs/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh /root/
RUN chmod 500 run_openemr.sh autoconfig.sh /root/unlock_admin.sh \
    && chmod 000 auto_configure.php /root/unlock_admin.php
#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2
#Copy dev tools alias to root and create snapshots and certs dir
COPY utilities/devtools /root/
COPY utilities/devtoolsLibrary.source /root/
RUN mkdir /snapshots
RUN mkdir /certs
RUN mkdir -p /couchdb/original
#Copy demo data to root
COPY utilities/demo_5_0_0_5.sql /root/
RUN chmod 500 /root/devtools
#Ensure swarm/orchestration pieces are available if needed
RUN mkdir /swarm-pieces \
    && rsync --owner --group --perms --delete --recursive --links /etc/ssl /swarm-pieces/
#go
CMD [ "./run_openemr.sh" ]

EXPOSE 80 443
