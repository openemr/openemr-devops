FROM alpine:latest

#Install dependencies
RUN apk add --no-cache apache2 git php7 php7-ctype php7-tokenizer php7-session php7-apache2 php7-xml php7-json php7-pdo php7-pdo_mysql php7-curl php7-ldap php7-mcrypt php7-xml php7-soap php7-mbstring curl php7-mysqli 
#clone openemr
RUN git clone https://github.com/openemr/openemr.git --depth 1 \
    && rm -rf openemr/.git \
    && chmod 666 openemr/sites/default/sqlconf.php \
    && chmod 666 openemr/interface/modules/zend_modules/config/application.config.php \
    && chown -R apache openemr/ \
    && mv openemr /var/www/localhost/htdocs/
#configure apache & php properly
COPY php.ini /etc/php7/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2
#go
ENV APACHE_LOG_DIR=/var/log/apache2
CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]

EXPOSE 80