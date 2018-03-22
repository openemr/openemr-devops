# OpenEMR Developer Utilities

## Bootstrap VM Candidate

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

## vm-\*.sh

These scripts are only of interest to OpenEMR developers preparing product releases, and are mentioned here for completeness only.
