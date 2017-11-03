# OpenEMR Standard: AMI Creation

These are of interest to OpenEMR developers only.

## Bootstrap

Generate an instance in us-east-1, and...

```
cd /root
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/stacks/AWS-mktplace/ami/ami-build.sh > bootstrap.sh
chmod a+x bootstrap.sh
./bootstrap.sh
rm bootstrap.sh
/root/openemr-devops/stacks/AWS-mktplace/ami/ami-seal.sh
```
