# Percona MySQL server with Percona Tools, Replication Support & Shared Volume Initialization

This Dockerfile has full test coverage. You can run the specs through `bin/spec`. A caveat is that some of these specs rely on `boot2docker`. This is due to this container being developed on OS X. Before running the spec do `bundle install` and `docker pull klevo/test_mysql_master`.

To run a container with a mysql data dir mounted for persistence:

```
docker run -d --name percona \
  -v /home/docker/percona-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=mypass \
  -p 3308:3306 \
  klevo/percona
```

## Hot Backups

Percona XtraBackup included. To do a hot backup on a running container:

```
docker exec -i -t percona innobackupex /backups
docker exec -i -t percona innobackupex --apply-log /backups/2014-12-16_14-44-35
```

## Replication Over SSH Tunnel

This container includes `autossh` which creates a tunnel to the master server if the below env variables are specified. The master must have a `tunnels` user account available which is reacheable through `ssh` with the slave's private key, which is mounted in the example below. Run a container with replication enabled like this:

```
docker run -d --name db1_slave \
  -v /home/docker/percona-data:/var/lib/mysql \
  -v /tunnels_id_rsa:/tunnels_id_rsa \
  -e MYSQL_ROOT_PASSWORD=mypass \
  -e REPLICATION_SLAVE_MASTER_HOST=someip \
  -e REPLICATION_SLAVE_REMOTE_PORT=3306 \
  -e REPLICATION_SLAVE_USER=slave_db1 \
  -e REPLICATION_SLAVE_PASSWORD=slaveuserpass \
  -p 3308:3306 \
  klevo/percona
```

Then get the SQL for master to set up the replication:

```
docker exec -i -t db1_slave replication_master_sql
```

outputs something like:

```
GRANT REPLICATION SLAVE ON *.* TO 'slave_db1'@'localhost' IDENTIFIED BY 'slaveuserpass';
```

Finally start replication on the slave (execute this once master was configured with the above sql):

```
docker exec -i -t db1_slave start_replication mysql-bin.000001 107
```

Runs something like this in the background on the slave container:

```
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='127.0.0.1', MASTER_USER='slave_db1', MASTER_PASSWORD='slaveuserpass', MASTER_PORT=3307, MASTER_LOG_FILE='mysql-bin.000001', MASTER_LOG_POS=107;
START SLAVE;
```

This was fun to write a spec for :)

### Create a master db container for testing

If you want to test the replication over the ssh tunnel with two docker containers, use my testing image: `klevo/test_mysql_master` and check the README.
