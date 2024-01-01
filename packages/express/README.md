# OpenEMR Cloud Express

OpenEMR Cloud Express on the AWS Marketplace provides OpenEMR 7.0.2, an embedded MySQL server, and rotated, automatic backups of all OpenEMR configuration and health information.

## Installation

### Requirements

Before you begin, you will need to create an SSH key pair in Amazon EC2, in the region you wish to launch OpenEMR. [Amazon's documentation](http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html#having-ec2-create-your-key-pair) covers this process in more detail.

### Directions

1. Navigate to the OpenEMR Cloud Express [Marketplace entry](https://aws.amazon.com/marketplace/pp/B077G76DWN).
2. Click *Continue*.
3. Leave the *1-Click Launch* tab selected.
4. Select the AWS region in which you wish to launch OpenEMR.
5. Select the size of the instance; you can see the approximate monthly cost calculated in the right column.
6. The VPC and subnet defaults are adequate, but you may change them if you wish to integrate the new instance with an existing VPC.
7. Select a security group to use for the new instance. The default group is adequate, but you should adjust the SSH port to allow traffic only from "My IP" instead of "Anywhere".
8. Select the EC2 key pair (discussed in Requirements) to assign to this instance.
9. Review these changes, and click *Launch with 1-Click* when you're ready.

### Usage

Navigate to the EC2 Console, and observe the instance that was just created. (The name of the instance will be blank; take this opportunity to name it.) Click the instance, and note the *Public DNS*, given as a hostname ending in "amazonaws.com", and the *Instance ID*, given as "i-" plus a long string of letters and numbers.

In a couple of minutes, once OpenEMR has finished the final setup procedures, it will start responding on `http://<Public DNS>`. Login with a user name of `admin` and a password of `<Instance ID>`.

## Administration

### General

* Need access to the containers? Connect to user `ubuntu`, sudo to root, and...
  * Apache: `docker exec -it $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh`
  * MySQL: `docker exec -it $(docker ps | grep mysql | cut -f 1 -d " ") /bin/bash`
* Visit container volume: `docker volume ls`, `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`

#### Set Local Timezone

1. See http://php.net/manual/en/timezones.php for the PHP timezone for your region.
2. `sudo bash`
3. `docker exec $(docker ps | grep _openemr | cut -f 1 -d " ") sed -i 's^;date.timezone\ =^date.timezone = <your timezone>^' /etc/php7/php.ini`
4. `docker restart $(docker ps | grep _openemr | cut -f 1 -d " ")`

### HIPAA Compliance

Although Amazon EC2 is a [HIPAA Eligible Service](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/), the Marketplace-supplied instance of OpenEMR Cloud Express does not meet some parts of the HIPAA Security Rule. HIPAA Covered Entities may not store Protected Health Information on this product, and should confine their use of OpenEMR Cloud Express to demonstration or training use only.

### Backups

Duplicity is installed to the host machine to manage and rotate backups. It can be configured to send the backups it creates to off-instance storage, but currently does not attempt to do so. `/etc/cron.daily/duplicity-backups` holds the daily backup process that snapshots both the MySQL database, the OpenEMR configuration, and any patient documents that have been created, storing them in `/root/backups`.

Full backups are made every seven days, with incrementals for the other days. The Duplicity backups encompass the MySQL database backups.

#### Recovering from Backup

It is recommended, in the strongest possible terms, that you familiarize yourself with the recovery process as soon as possible. Launch a backup process, move the created backup files to a fresh instance, and try to recover them &mdash; this test, performed regularly, ensures smooth recovery in the face of catastrophe.

1. If necessary, place the compressed backup archive bundle in `/root/backups`.
2. As root, launch `/root/restore.sh`, and carefully read the warning it supplies you.
3. Take the actions it suggests &mdash; make an image snapshot if possible &mdash; and then, once ready, edit the script as instructed and run it anew.
4. Duplicity will unpack the MySQL backups it's holding, the OpenEMR configuration directory, and any patient documents that have been saved.
5. XtraBackup will launch, applying the most recent full backup and all the daily incrementals.
6. The MySQL container will be restarted to pick up the newly constructed data directory, and at this point your backups should be completely restored.

See the `mysql-xtrabackup` container for more information about the `xbackup.sh` and `xrecovery.sh` scripts called by the Duplicity wrappers.

#### Backup Cross-Compatibility

OpenEMR Cloud Express backup files are cross-compatible with the [Appliance](../appliance) and [Ubuntu Installer](../lightsail) deployment packages; you should be able to migrate your practice between any of the three if you move the backups onto the target.

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and it is encouraged that you explore them as soon as possible.

## Support

The OpenEMR [forums](https://community.open-emr.org/) are available if you have any questions. We'll be happy to help!
