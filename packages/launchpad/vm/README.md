# OpenEMR Developer Utilities

## Bootstrap VM Candidate

create a working image
```
LOCALPROJECT=[REDACTED]
gcloud config set project $LOCALPROJECT
gcloud config set compute/zone us-east1-b
# just did it manually through console instead of this -- Ubuntu 16.04 LTS
# TODO: following doesn't work, needs OS specification
gcloud compute instances create ${INSTANCE} --scopes https://www.googleapis.com/auth/cloud-platform 
```

inside the image
```
cd /root
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/lightsail/launch.sh > ./launch.sh
chmod +x ./launch.sh
./launch.sh -s 0
rm ./launch.sh
cd openemr-devops/packages/launchpad/vm
chmod +x *.sh
# manual entry of root password required at this next step
./vm-lock.sh
./vm-seal.sh
```

during the cleaning pass
TODO: insufficent? do find traces in /etc/passwd and home directory permissions
```
mkdir /mnt/openemr
mount -o defaults /dev/sdb1 /mnt/openemr
find /mnt/openemr/home/* -prune | grep -v home/ubuntu | xargs rm -rf
sync ; shutdown -h now
```

to create the image from Google Cloud Shell
```
LOCALPROJECT=[ACCOUNT REDACTED]
LOCALDISK=[cleaned project disk]
gcloud config set project $LOCALPROJECT
gcloud config set compute/zone us-east1-b
curl -O https://storage.googleapis.com/c2d-install-scripts/partner-utils.tar.gz
tar -xzvf partner-utils.tar.gz
python setup.py install
# change created disk name and target image name to suit
# test
python image_creator.py --project $LOCALPROJECT --disk $LOCALDISK --name oemr-ubuntu-launchpad-20180524 --license 
oemr-public/openemr-launchpad
# production
# python image_creator.py --project $LOCALPROJECT --disk $LOCALDISK --name oemr-ubuntu-launchpad-20180524 --destination-project [ACCOUNT REDACTED] --license oemr-public/openemr-launchpad
```

now incorporate it into deployment package

## vm-\*.sh

These scripts are only of interest to OpenEMR developers preparing product releases, and are mentioned here for completeness only.
