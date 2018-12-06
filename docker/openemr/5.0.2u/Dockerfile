FROM owasp/modsecurity:v2-ubuntu-apache
MAINTAINER Chaim Sanders chaim.sanders@gmail.com

ARG COMMIT=v3.1/dev
ARG REPO=SpiderLabs/owasp-modsecurity-crs
ENV PARANOIA=1
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

#Install dependencies
RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get -y install perl python php7.2 curl mysql-client nodejs git \ 
    php7.2 libapache2-mod-php7.2 php7.2-dev php7.2-curl php7.2-ldap php7.2-gd php7.2-mbstring \
    php7.2-zip php7.2-ldap php7.2-soap php7.2-mysqli php7.2-sockets php7.2-redis \
    php7.2-redis php7.2-simplexml php7.2-xmlwriter php7.2-phar php7.2-json \ 
    php7.2-iconv php7.2-xml php7.2-xsl php7.2-pdo php7.2-ctype \ 
    php7.2-tokenizer

# Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
#RUN usermod -u 1000 apache
# Install composer for openemr package building
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer
#clone openemr

 RUN git clone https://github.com/openemr/openemr.git --depth 1 \
    && rm -rf openemr/.git \
    && cd openemr \
    && rm -f composer.lock \
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
    && chmod 666 openemr/interface/modules/zend_modules/config/application.config.php \
    && chown -R apache openemr/ \
    && mv openemr /var/www/localhost/htdocs/ \
    && git clone https://github.com/letsencrypt/letsencrypt /opt/certbot \
    && pip install -e /opt/certbot/acme -e /opt/certbot \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
WORKDIR /var/www/localhost/htdocs/openemr
VOLUME [ "/etc/letsencrypt/", "/etc/ssl" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php7.2/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY run_openemr.sh autoconfig.sh auto_configure.php /var/www/localhost/htdocs/openemr/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh /root/
RUN chmod 500 run_openemr.sh autoconfig.sh /root/unlock_admin.sh \
    && chmod 000 auto_configure.php /root/unlock_admin.php
#fix issue with apache2 dying prematurely
RUN rm -f /etc/apache2/httpd.conf
COPY httpd.conf /etc/apache2/
RUN mkdir -p /run/apache2


RUN cd /opt && \
  git clone https://github.com/${REPO}.git owasp-modsecurity-crs-3.1 && \
  cd owasp-modsecurity-crs-3.1 && \
  git checkout -qf ${COMMIT} 

RUN cd /opt && \
  cp -R /opt/owasp-modsecurity-crs-3.1/ /etc/apache2/modsecurity.d/owasp-crs/ && \
  mv /etc/apache2/modsecurity.d/owasp-crs/crs-setup.conf.example /etc/apache2/modsecurity.d/owasp-crs/crs-setup.conf && \
  cd /etc/apache2/modsecurity.d && \
  printf "include modsecurity.d/owasp-crs/crs-setup.conf\ninclude modsecurity.d/owasp-crs/rules/*.conf" > include.conf && \
  sed -i -e 's/SecRuleEngine DetectionOnly/SecRuleEngine On/g' /etc/apache2/modsecurity.d/modsecurity.conf && \
  a2enmod proxy proxy_http


#go
CMD [ "./run_openemr.sh" ]

EXPOSE 80 443
