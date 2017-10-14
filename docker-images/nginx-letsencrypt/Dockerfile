FROM alpine:3.6

RUN apk add --no-cache --update nginx certbot \
    && mkdir /run/nginx
# wget ca-certificates openssl gnupg \
##    && wget https://dl.eff.org/certbot-auto \
 #   && chmod a+x ./certbot-auto \
 #   && wget -N https://dl.eff.org/certbot-auto.asc \
 #   && gpg2 --keyserver hkps.pool.sks-keyservers.net --recv-key A2CFB51FA275A7286234E7B24D17C995CD9775F2 \
 #   && gpg2 --trusted-key 4D17C995CD9775F2 --verify certbot-auto.asc certbot-auto \
 #   && ./certbot-auto --help \
 
ENV TARGET=target
COPY "nginx.conf" "/etc/nginx/"

RUN apk del --no-cache wget gnupg
VOLUME "/etc/"
CMD sed -i -- "s/proxy.target/$TARGET/g" /etc/nginx/nginx.conf && nginx -g "daemon off;"