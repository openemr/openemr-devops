# OpenEMR Developer Utilities

## Bootstrap AMI Candidate

```
cd /root
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/lightsail/launch.sh > ./launch.sh
chmod +x ./launch.sh
./launch.sh -s 0
rm ./launch.sh
cd openemr-devops/packages/express/ami
chmod +x *.sh
# manual entry of root password required at this next step
./ami-lock.sh
./ami-seal.sh
```

## ami-\*.sh

These scripts are only of interest to OpenEMR developers preparing product releases, and are mentioned here for completeness only.
