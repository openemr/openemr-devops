# OpenEMR Cloud Express Plus

This process will install a fully-functional, secured, preconfigured OpenEMR 7.0.0 instance on an AWS Ubuntu server (and several other Amazon services), providing an embedded MySQL server and rotated, automatic backups of all OpenEMR configuration and health information.

## Installation

### AWS CloudFormation

We offer an AWS CloudFormation template, which slightly increases the billable AWS resources past a single server (expected additional outlay: $2-$5/mo) but offers HIPAA eligibility, backups uploaded daily to S3, CloudTrail auditing, and AWS KMS encryption of all Protected Health Information at all steps of its lifecycle.

1. Be sure you have a valid [EC2 keypair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-key-pairs.html) for the region you're planning to launch your instance in.
2. Click [here](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=OpenEMR&templateURL=https://s3.amazonaws.com/openemr-cfn-useast1/OpenEMR-Express-Plus.json) to launch in `us-east-1` (North Virginia), or submit our template `https://s3.amazonaws.com/openemr-cfn-useast1/OpenEMR-Express-Plus.json` to CloudFormation in the region you'd prefer instead.   
3. Enter your primary key, your Express instance size, and the amount of storage to reserve for your practice.
4. Proceed and launch.
5. Once CloudFormation finishes the stack, you may log in to the IP given in the ``Output`` tab.
   * User: `admin`
   * Password: `pass`
   * Change this password before proceeding.

## Administration

### General

* The instance should be answering on port 80 inside of ten minutes. If it's not...
  * `tail -f /tmp/launch.log` to see if it's still running, or where it got stuck.
  * Transient build failures are possible if container dependencies are temporarily unavailable, just retry.
  * You will need network access, don't try to build from a private IP without NAT egress.
  * Check the process list, make sure `auto_configure.php` isn't running before you attempt to log in.
  * Some region-specific hardcoding is required, and if AWS has released a new region you might be the first to notice we're not supporting it yet. Reach out on the forums if CloudFormation can't resolve the template for your area.
* Express Plus is based on our [master installation script](../lightsail) which contains complete notes on common administration tasks, including container interaction and installation of SSL certificates.

### HIPAA Compliance

a. For AWS customers that are HIPAA covered entities, before deployment of OpenEMR Express Plus, you must navigate to the Services->Artifact->Agreements section of the AWS console, find the AWS Nondisclosure Agreement (AWS Artifact NDA).  Download, read and accept it.  Then find the AWS Business Associate Addendum (AWS BAA).  Download, read and accept it.

b. For AWS customers that are HIPAA covered entities, OpenEMR Express Plus must be deployed in the U.S. East (N. Virginia) Region (preferred) or U.S. West (Oregon) Region.

### Backups

Duplicity is installed to the host machine to manage and rotate backups, sending encrypted backups to a KMS-managed Amazon S3 bucket allocated by CloudFormation. `/etc/cron.daily/duplicity-backups` holds the daily backup process that snapshots both the MySQL database, the OpenEMR configuration, and any patient documents that have been created.

Full backups are made every seven days, with incrementals for the other days. The Duplicity backups encompass the MySQL database backups.

#### Recovering from Backup

It is recommended, in the strongest possible terms, that you familiarize yourself with the recovery process as soon as possible.

1. As root, launch `/root/restore.sh`, and carefully read the warning it supplies you.
2. Take the actions it suggests &mdash; make an image snapshot if possible &mdash; and then, once ready, run the script as instructed.
3. Duplicity will unpack the MySQL backups it's holding, the OpenEMR configuration directory, and any patient documents that have been saved.
4. XtraBackup will launch, applying the most recent full backup and all the daily incrementals.
5. The MySQL container will be restarted to pick up the newly constructed data directory, and at this point your backups should be completely restored.

See the `mysql-xtrabackup` container for more information about the `xbackup.sh` and `xrecovery.sh` scripts called by the Duplicity wrappers.

### stack.py

The CloudFormation stack is created from a Python-based stack builder, providing a significantly clearer reading experience.

```
$ cd packages/express_plus
$ pip install -r requirements.txt
$ python stack.py > OpenEMR-Express-Plus.json
```

#### Windows Interactions

Note that if you run Python from PowerShell your console output will be in UTF-16 encoding, which CloudFormation cannot directly import. Please use the enclosed `stackmaker` batchfile to produce UTF-8.
## Support

The OpenEMR [forums](https://community.open-emr.org/) and Slack are available if you have any questions. We'll be happy to help!
