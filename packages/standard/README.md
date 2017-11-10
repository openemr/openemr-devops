# OpenEMR Standard

## Introduction

OpenEMR is a 2014 ONC Complete EHR Certified medical practice management solution. OpenEMR Standard is a HIPAA-eligible deployment for the Amazon Marketplace &mdash; consult the [datasheet](http://www.open-emr.org/wiki/index.php/OpenEMR_Cloud_Standard_Data_Sheet) for further details.

## Administration

* Access the OpenEMR container: `sudo docker exec -it $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh`
* Visit container volume: `docker volume ls`, `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`

### Backups

Your RDS instance will take regular automated snapshots at the configured time of day, and encrypted backups of the OpenEMR filesystem and patient records are made via Duplicity to a stack-provided KMS-managed S3 bucket.

* Restore from the most recent Duplicity backup with `sudo /root/restore.sh`.
* Restore the most recent snapshot via the AWS console, and update your OpenEMR configuration file with the endpoint of the new instance.

## Legal Note

[End User License Agreement](https://github.com/openemr/openemr-devops/tree/master/stacks/AWS-mktplace/EULA.txt)
