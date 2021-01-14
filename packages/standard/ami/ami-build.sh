#!/bin/bash

exec > /var/log/openemr-launch.log 2>&1

REPOBRANCH=master
DOCKERLABEL=:6.0.0

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
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --force-yes

# grab packages
apt-get install -y apt-transport-https ca-certificates git jq duplicity awscli python-boto python-pip

# CloudFormation hooks
pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz

# get production Docker pages
apt-get update
apt-get install jq git duplicity -y
apt-get install apt-transport-https ca-certificates curl gnupg-agent software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
# apt-key fingerprint 0EBFCD88
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install docker-ce docker-ce-cli containerd.io docker-compose -y

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
curl -L https://github.com/docker/compose/releases/download/1.15.0/docker-compose-`uname -s`-`uname -m` > docker-compose
chmod +x docker-compose

echo ami-build.sh: done
