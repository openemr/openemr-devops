#!/bin/bash

exec > /var/log/openemr-launch.log 2>&1

REPOBRANCH=master
DOCKERLABEL=:6.1.0

while getopts "b:d:" opt; do
  case $opt in
    b)
      REPOBRANCH=$OPTARG
      ;;
    d)
      DOCKERLABEL=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$opt" >&2
      exit 1
      ;;
  esac
done

# pull in all updates
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --force-yes

# grab packages
apt-get install -y git jq duplicity awscli python3-boto python3-pip containerd docker-compose

# CloudFormation hooks
pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz
ln -s /root/aws-cfn-bootstrap-latest/init/ubuntu/cfn-hup /etc/init.d/cfn-hup

# grab our Docker instance
docker pull openemr/openemr${DOCKERLABEL}

# get the rest of the devops repo and docker-tools
cd /root
if [[ $REPOBRANCH == master ]]; then
  git clone --single-branch https://github.com/openemr/openemr-devops.git && cd openemr-devops/packages/standard
else
  git clone --single-branch --branch $REPOBRANCH https://github.com/openemr/openemr-devops.git && cd openemr-devops/packages/standard
fi
chmod +x ami/*.sh scripts/*.sh

echo ami-build.sh: done
