# OpenEMR Cloud Express

This process will install a fully-functional, secured, preconfigured OpenEMR 5.0.0 instance on your Ubuntu server, providing an embedded MySQL server and rotated, automatic backups of all OpenEMR configuration and health information. While AWS is the main target, there is documentation around deploying on-premise as well.

## Installation

### AWS Marketplace

1. From the AWS EC2 Dashboard, select *Launch Instance*.
2. Select *AWS Marketplace*, search for `OpenEMR Express`, then *Select* it.
3. Select *Continue*.
4. Select a suitable instance type (we recommend a minimum `t2.small`), then *Next: Configure Instance Details*.
5. Specify how you'd like the instance connected to Amazon's network and the internet, then select *Next: Add Storage*.
   * Your default VPC will probably be fine. *Auto-Assign Public IP* should be `Enable`.
6. Create a root instance with enough room to hold your projected patient files, minimum *8* GB, and then select *Next: Add Tags*.
7. Assuming you don't have any tags to add here, proceed to *Next: Configure Security Group*.
8. Select `Select an existing security group` to accept the default OpenEMR security settings, which you can customize.
   * You probably don't want SSH open to the world &mdash; you could tighten it to just your own IP, or just your office, right now.
9. Select *Review and Launch*, then *Launch*, then *View Instances*.
   * A message box concerning keypairs may show up, simply follow the prompts.
10. Click the instance in EC2 that's currently being created. Note the *IPv4 Public IP* and *Instance ID* entries.
11. Your OpenEMR installation is being constructed! In a few minutes, you can log in.
    * URL: `http://your-public-ip`
    * Username: `admin`
    * Password: `your-instance-id` (this will start with 'i-')

### AWS Lightsail

1. From the AWS Lightsail Dashboard, click *Create Instance*.
2. Consider changing your region, or accept the datacenter Amazon has selected.
3. For *Instance Image*, select *OS Only*, then *Ubuntu 16.04 LTS*.
4. Click the *+* to add a launch script, then paste the following.
```
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/stacks/single-server/launch.sh > ./launch.sh
chmod +x ./launch.sh && sudo ./launch.sh
```
5. Select an instance size that meets your budget.
6. Name your instance and click *Create*.
7. The instance will shortly be visible as `Pending`, and then `Active`.
8. Before you connect, select `...`, then `Manage`, then the `Networking` tab, and add the `HTTPS` port to the firewall pass-through.
9. You can connect to the instance (see below) and monitor the logs, or you can let it bake for perhaps ten minutes. Either way, once installation has completed, browse to the IP shown in Lightsail and log in to OpenEMR.
   * Login: `admin`
   * Password: `pass`
   * After login, under `Administration` and `Users`, you'll find the `admin` user and a chance to change that password.   
   * Optionally connect with https://&lt;your instance ip&gt;, using the temporary self-signed certificate. Accept the security exception for now.
10. OpenEMR is now ready for use!

### AWS CloudFormation

We offer an AWS CloudFormation template, which slightly increases the billable AWS resources past a single server (expected additional outlay: $2-$5/mo) but offers HIPAA eligibility, backups uploaded daily to S3, CloudTrail auditing, and AWS KMS encryption of all Protected Health Information at all steps of its lifecycle.

1. Click the link corresponding to the region you plan to launch.
   * [N. Virginia](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-useast1/OpenEMR-Express.json) (least expensive)
   * [Ohio](https://console.aws.amazon.com/cloudformation/home?region=us-east-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-useast2/OpenEMR-Express.json)
   * [N. California](https://console.aws.amazon.com/cloudformation/home?region=us-west-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-uswest1/OpenEMR-Express.json)  
   * [Oregon](https://console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-uswest2/OpenEMR-Express.json)  
   * [Mumbai](https://console.aws.amazon.com/cloudformation/home?region=ap-south-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-apsouth1/OpenEMR-Express.json)  
   * [Seoul](https://console.aws.amazon.com/cloudformation/home?region=ap-northeast-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-apnortheast2/OpenEMR-Express.json)  
   * [Singapore](https://console.aws.amazon.com/cloudformation/home?region=ap-southeast-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-apsoutheast1/OpenEMR-Express.json)  
   * [Sydney](https://console.aws.amazon.com/cloudformation/home?region=ap-southeast-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-apsoutheast2/OpenEMR-Express.json)  
   * [Tokyo](https://console.aws.amazon.com/cloudformation/home?region=ap-northeast-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-apnortheast1/OpenEMR-Express.json)  
   * [Canada](https://console.aws.amazon.com/cloudformation/home?region=ca-central-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-cacentral1/OpenEMR-Express.json)  
   * [Frankfurt](https://console.aws.amazon.com/cloudformation/home?region=eu-central-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-eucentral1/OpenEMR-Express.json)  
   * [Ireland](https://console.aws.amazon.com/cloudformation/home?region=eu-west-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-euwest1/OpenEMR-Express.json)  
   * [London](https://console.aws.amazon.com/cloudformation/home?region=eu-west-2#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-euwest2/OpenEMR-Express.json)  
   * [Sao Paolo](https://console.aws.amazon.com/cloudformation/home?region=sa-east-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-saeast1/OpenEMR-Express.json)  
2. Enter your primary key, your Express instance size, and the amount of storage to reserve for your practice.
3. Proceed and launch.
4. Once CloudFormation finishes the stack, you may log in to the IP given in the ``Output`` tab.
   * User: `admin`
   * Password: `pass`
   * Change this password before proceeding.

### Custom Installation

#### Requirements

* Ubuntu 16.04 server (root access, 512 MB RAM, 20 GB storage)
* Outbound internet access (during installation)

#### Synopsis

Although built for AWS Lightsail and EC2 Marketplace, nothing in `launch.sh` is specific to that platform; on any Ubuntu 16.04 instance, you may download and run the script as root to install the two Docker containers, `openemr` and `mysql-xtrabackup`, that represent the application. If you have more than a gigabyte of memory, or you are specifically billed for I/O activity, you may wish to review the command-line parameters to disable the automatic allocation of swap space.

#### Directions

To install, run the same launch script, make sure you're provided inbound access to ports 22, 80 and 443, and largely follow the Lightsail directions as given.

## Administration

### General

* The instance should be answering on port 80 inside of ten minutes. If it's not...
  * `tail -f /tmp/launch.log` to see if it's still running, or where it got stuck.
  * Transient build failures are possible if container dependencies are temporarily unavailable, just retry.
  * You will need network access, don't try to build from a private IP without NAT egress.
  * Check the process list, make sure `auto_configure.php` isn't running before you attempt to log in.
* Need access to the containers? Log into root, and...
  * Apache: `docker exec -it $(docker ps | grep _openemr | cut -f 1 -d " ") /bin/sh`
  * MySQL: `docker exec -it $(docker ps | grep mysql | cut -f 1 -d " ") /bin/bash`
* Visit container volume: `docker volume ls`, `cd $(docker volume inspect <volume_name> | jq -r ".[0].Mountpoint")`

### Lightsail Administration Notes

#### SSH Keys

Lightsail has its own SSH key manager, independent of EC2. You may create or upload a key you'd like Lightsail to use, or you can elect to use the Lightsail default key AWS assigns your account. If you don't download the key, you can still use the Lightsail-supplied browser client to securely connect to your instance. Click the icon of a monitor with a shell cursor to do so.

#### DNS, Static IP, Networking

Lightsail has the ability to assign static IPs to instances, and the ability to manage domains and subdomains to direct traffic to them, but a tutorial on their use is beyond the scope of this guide. The `Manage`, `Networking` options will allow you to control the ports available to the instance, perhaps turning SSH off when not in use (by you) for added security, or turning SSL on if a domain certificate is installed to the Apache container.

#### Snapshots

You can stop your OpenEMR instance to take a full copy of it, and then restart it; the snapshot copy will persist, and can be independently started as a separate instance, allowing you to create ad-hoc backups or test beds for OS upgrades, OpenEMR security patches, or to try out procedures like the recovery process before you use them in production.

#### HIPAA Compliance

As of September 2017, AWS Lightsail is not a [HIPAA Eligible Service](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/). HIPAA Covered Entities may not store Protected Health Information on AWS Lightsail, and should confine their use of OpenEMR Cloud Express to demonstration or training use only. (Use of the software on other servers may be possible and should be discussed with your compliance officer.)

### AWS Marketplace

#### HIPAA Compliance

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

### Next Steps

There is an important and immediate flaw in the backup regimen to address &mdash; your backups will not be stored safely off the instance; until this is amended, if something happens to the server, your backups will be lost as well. Duplicity can be configured with a *bewildering* array of remote storage backends, and it is encouraged that you explore them as soon as possible.

## Developer Notes

### launch.sh Command-Line Parameters

* *-b* &lt;branch-name&gt;: load specific branch of openemr-devops repository
* *-s* &lt;swap-size-GB&gt;: amount of swap to allocate for small instances; 0 for none
* *-d*: use the developer docker-compose file variant
  * use `build` directive instead of `image` to run repository containers instead of hub
  * force MySQL port world-readable

## Support

The OpenEMR [forums](https://community.open-emr.org/) and [chat](https://chat.open-emr.org/) are available if you have any questions. We'll be happy to help!
