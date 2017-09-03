# OpenEMR Docker

## AWS LightSail

https://davekz.com/docker-on-lightsail/

Base OS, "Ubuntu 16.04", paste, go
```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/wip-duplicity/docker/lightsail-launch.sh > lightsail-launch.sh
chmod +x lightsail-launch.sh
sudo ./lightsail-launch.sh
```

openemr config: do not create db, mysql server 'mysql', creds "root/root"

### Instance management notes

 * install failure? see logs in /tmp/lightsail-launch.log (tail -f to see when initial install is done)
 * Connect to webserver: Alpine has no bash, so `docker ps`, `docker exec -i -t <instance id> /bin/sh`
 * Connect to mysql: `docker ps`, `docker exec -i -t <instance id> /bin/bash`
