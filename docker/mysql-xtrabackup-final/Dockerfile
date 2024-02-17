FROM openemr/mysql-xtrabackup:1.0.7

RUN rm /root/xbackup-wrapper.sh /root/xrecovery-final.sh
COPY xbackup-wrapper.sh xrecovery-final.sh /root/
RUN chmod a+x /root/*.sh