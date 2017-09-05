FROM ubuntu:14.04

ENV LAST_UPDATED 20150504

# Install Percona Server, client, toolkit and xtrabackup.
RUN \
  apt-key adv --keyserver keys.gnupg.net --recv-keys 8507EFA5 && \
  echo "deb http://repo.percona.com/apt `lsb_release -cs` main" > /etc/apt/sources.list.d/percona.list && \
  apt-get update && \
  apt-get -y upgrade && \
  apt-get install -y percona-server-server-5.6 percona-server-client-5.6 percona-toolkit percona-xtrabackup qpress

# Empty mysql data dir, so that our init script can start from a clean slate
RUN rm -rf /var/lib/mysql/*

# Define mountable directories.
VOLUME ["/etc/mysql", "/var/lib/mysql", "/backups"]

# Add a default, tweaked mysql config. In production should be replaced by a mounted volume, with your own config managed by your orchestration solution (Chef, etc.)
COPY mysql/my.cnf /etc/mysql/my.cnf

COPY scripts/* /usr/bin/

RUN chmod a+x /usr/bin/mysqld_with_init /usr/bin/create_my_root_cnf

# Define default command.
CMD ["mysqld_with_init"]

# Expose ports.
EXPOSE 3306
