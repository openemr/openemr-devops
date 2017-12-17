# OpenEMR Standard: AMI Creation

These are of interest to OpenEMR developers only.

## Bootstrap

Generate an instance in us-east-1, and...

```
cd /root
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/standard/ami/ami-build.sh > bootstrap.sh
chmod a+x bootstrap.sh
./bootstrap.sh
rm bootstrap.sh
./openemr-devops/packages/standard/ami/ami-seal.sh
```
