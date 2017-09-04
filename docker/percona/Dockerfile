FROM ubuntu:14.04

ENV LAST_UPDATED 20150504

# Install Percona Server, client, toolkit and xtrabackup.
RUN \
  apt-key adv --keyserver keys.gnupg.net --recv-keys 1C4CBDCDCD2EFD2A && \
  echo "deb http://repo.percona.com/apt `lsb_release -cs` main" > /etc/apt/sources.list.d/percona.list && \
  apt-get update && \
  apt-get -y upgrade && \
  apt-get install -y percona-server-server-5.6 percona-server-client-5.6 percona-toolkit percona-xtrabackup qpress

# Install autossh for permanent tunnel creation.
RUN apt-get install -y autossh

# Empty mysql data dir, so that our init script can start from a clean slate
RUN rm -rf /var/lib/mysql/*

# Define mountable directories.
VOLUME ["/etc/mysql", "/var/lib/mysql", "/backups"]

# Add a default, tweaked mysql config. In production should be replaced by a mounted volume, with your own config managed by your orchestration solution (Chef, etc.)
ADD mysql/my.cnf /etc/mysql/my.cnf

ADD scripts/* /usr/bin/

# Define default command.
CMD ["mysqld_with_init"]

# Expose ports.
EXPOSE 3306