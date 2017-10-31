# OpenEMR Hyper

(that's not what it's called)

## Bootstrap Process

```
cd /root
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/wip-aws-mktplace/stacks/AWS-mktplace/ami-build.sh > bootstrap.sh
chmod a+x bootstrap.sh
./bootstrap.sh -b wip-aws-mktplace
rm bootstrap.sh
/root/openemr-devops/stacks/AWS-mktplace/ami-seal.sh
```
