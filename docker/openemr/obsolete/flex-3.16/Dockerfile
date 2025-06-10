FROM alpine:3.16

#Install dependencies and fix issue in apache
RUN apk --no-cache upgrade
RUN apk add --no-cache \
    apache2 apache2-ssl apache2-utils git php81 php81-tokenizer php81-ctype php81-session php81-apache2 \
    php81-json php81-pdo php81-pdo_mysql php81-curl php81-ldap php81-openssl php81-iconv \
    php81-xml php81-xsl php81-gd php81-zip php81-soap php81-mbstring php81-zlib \
    php81-mysqli php81-sockets php81-xmlreader php81-redis perl php81-simplexml php81-xmlwriter php81-phar php81-fileinfo \
    php81-sodium php81-calendar php81-intl \
    mysql-client tar curl imagemagick nodejs npm \
    python3 openssl git py-pip openssl-dev dcron \
    rsync shadow jq ncurses \
    && sed -i 's/^Listen 80$/Listen 0.0.0.0:80/' /etc/apache2/httpd.conf
# Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
    RUN usermod -u 1000 apache
#Stuff for developers since this predominantly a developer/tester docker
RUN apk add --no-cache \
    unzip vim nano bash bash-doc bash-completion tree

#BELOW LINE NEEDED TO SUPPORT PHP8 ON ALPINE 3.13+; SHOULD BE ABLE TO REMOVE THIS IN FUTURE ALPINE VERSIONS
RUN cp /usr/bin/php81 /usr/bin/php
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer

# TODO: Note that flex series 3.14+ needs to keep build-base package in (ie. not apk del it after done) for now
#  since npm package libxmljs needs to be built during openemr build; this is part of the ccda npm build and
#  can place build-base in below apk del line when this issue is fixed)
#  btw, when this is fixed and we apk del build-base, this will decrease size of docker by 190MB :)
RUN apk add --no-cache build-base libffi-dev python3-dev cargo \
    && mkdir -p /var/www/localhost/htdocs/openemr/sites \
    && chown -R apache /var/www/localhost/htdocs/openemr \
    && git clone https://github.com/letsencrypt/letsencrypt --depth 1 /opt/certbot \
    && pip install --upgrade pip \
    && pip install -e /opt/certbot/acme -e /opt/certbot/certbot \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
    && apk del --no-cache libffi-dev python3-dev cargo \    
    && sed -i 's/^ *CustomLog/#CustomLog/' /etc/apache2/httpd.conf \
    && sed -i 's/^ *ErrorLog/#ErrorLog/' /etc/apache2/httpd.conf \
    && sed -i 's/^ *CustomLog/#CustomLog/' /etc/apache2/conf.d/ssl.conf \
    && sed -i 's/^ *TransferLog/#TransferLog/' /etc/apache2/conf.d/ssl.conf
WORKDIR /var/www/localhost/htdocs
VOLUME [ "/etc/letsencrypt/", "/etc/ssl" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php81/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY openemr.sh ssl.sh xdebug.sh auto_configure.php /var/www/localhost/htdocs/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh /root/
RUN chmod 500 openemr.sh ssl.sh xdebug.sh /root/unlock_admin.sh \
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
CMD [ "./openemr.sh" ]

EXPOSE 80 443
