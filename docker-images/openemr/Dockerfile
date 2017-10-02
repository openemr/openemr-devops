FROM alpine:3.5

#Install dependencies
RUN apk add --no-cache apache2 git php7 php7-ctype php7-session php7-apache2 php7-xml php7-json php7-pdo php7-pdo_mysql php7-curl php7-ldap php7-mcrypt php7-xml php7-xsl php7-gd php7-zip php7-soap php7-mbstring php7-mysqli curl imagemagick-dev
#php7-tokenizer will be needed when migrating to 7.1
#clone openemr
RUN git clone https://github.com/openemr/openemr.git --branch rel-500 --depth 1 \
    && rm -rf openemr/.git \
    && chmod 666 openemr/sites/default/sqlconf.php \
    && chmod 666 openemr/interface/modules/zend_modules/config/application.config.php \
    && chown -R apache openemr/ \
    && mv openemr /var/www/localhost/htdocs/
WORKDIR /var/www/localhost/htdocs/openemr
VOLUME [ "/var/www/localhost/htdocs/openemr/sites" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY php.ini /etc/php7/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY run_openemr.sh .
COPY auto_configure.php .
RUN chmod 700 run_openemr.sh \
    && chmod 000 auto_configure.php \
    && ln -s /usr/bin/php7 /usr/bin/php
#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2
#go
CMD [ "./run_openemr.sh" ]

EXPOSE 80