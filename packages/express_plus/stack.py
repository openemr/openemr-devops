#!/usr/bin/python
# -*- coding: utf-8 -*-

# TODO: work out S3 lifycycle rules to allow undeleting backups

from troposphere import Base64, FindInMap, GetAtt, GetAZs, Join, Select, Split, Output
from troposphere import Parameter, Ref, Tags, Template
from troposphere import ec2, kms, s3, cloudtrail, iam, cloudformation

import argparse

ref_stack_id = Ref('AWS::StackId')
ref_region = Ref('AWS::Region')
ref_stack_name = Ref('AWS::StackName')
ref_account = Ref('AWS::AccountId')

def setInputs(t, args):
    t.add_parameter(Parameter(
        'EC2KeyPair',
        Description = 'Amazon EC2 Key Pair',
        Type = 'AWS::EC2::KeyPair::KeyName'
    ))

    t.add_parameter(Parameter(
        'PracticeStorage',
        Description = 'Storage for the OpenEMR practice (minimum 10 GB)',
        Default = '10',
        Type = 'Number',
        MinValue = '10'
    ))

    t.add_parameter(Parameter(
        'InstanceSize',
        Description = 'EC2 instance size for the webserver (minimum t3.small recommended)',
        Default = 't3.small',
        Type = 'String',
        AllowedValues = [
            't3.micro', 't3.small', 't3.medium', 't3.large', 't3.xlarge', 't3.2xlarge'
        ]
    ))

    t.add_parameter(Parameter(
        'UbuntuAMI',
        Description = "Ubuntu 24.04 LTS AMI, resolved from Canonical's public SSM parameter (change only if you know what you're doing)",
        Default = '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id',
        Type = 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    ))

    return t

def setRecoveryInputs(t, args):
    # todo: duplicate Standard's organization and sorting
    t.add_parameter(Parameter(
        'EC2KeyPair',
        Description = 'Amazon EC2 Key Pair',
        Type = 'AWS::EC2::KeyPair::KeyName'
    ))

    t.add_parameter(Parameter(
        'PracticeStorage',
        Description = 'Storage for the OpenEMR practice (minimum 10 GB)',
        Default = '10',
        Type = 'Number',
        MinValue = '10'
    ))

    t.add_parameter(Parameter(
        'InstanceSize',
        Description = 'EC2 instance size for the webserver (minimum t3.small recommended)',
        Default = 't3.small',
        Type = 'String',
        AllowedValues = [
            't3.micro', 't3.small', 't3.medium', 't3.large', 't3.xlarge', 't3.2xlarge'
        ]
    ))

    t.add_parameter(Parameter(
        'RecoveryKMSKey',
        Description='Parent KMS ARN ("arn:aws:kms...")',
        Type='String'
    ))
    
    t.add_parameter(Parameter(
        'RecoveryS3Bucket',
        Description='Parent S3 bucket name',
        Type='String'
    ))

    t.add_parameter(Parameter(
        'UbuntuAMI',
        Description = "Ubuntu 24.04 LTS AMI, resolved from Canonical's public SSM parameter (change only if you know what you're doing)",
        Default = '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id',
        Type = 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>'
    ))

    return t

def setDeveloperInputs(t, args):
    t.add_parameter(Parameter(
        'DeploymentBranch',
        Description='openemr-devops branch to launch from',
        Default='master',
        Type='String'
    ))

def setMappings(t, args):
    # AMI selection moved to the UbuntuAMI SSM parameter; no static mappings remain
    return t

def buildInfrastructure(t, args):
    t.add_resource(
        ec2.VPC(
            'VPC',
            CidrBlock='10.0.0.0/16',
            EnableDnsSupport='true',
            EnableDnsHostnames='true'
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PublicSubnet1',
            VpcId = Ref('VPC'),
            CidrBlock = '10.0.1.0/24',
            AvailabilityZone = Select("0", GetAZs(""))
        )
    )


    t.add_resource(
        ec2.InternetGateway(
            'ig'
        )
    )

    t.add_resource(
        ec2.VPCGatewayAttachment(
            'igAttach',
            VpcId = Ref('VPC'),
            InternetGatewayId = Ref('ig')
        )
    )

    t.add_resource(
        ec2.RouteTable(
            'rtTablePublic',
            VpcId = Ref('VPC')
        )
    )

    t.add_resource(
        ec2.Route(
            'rtPublic',
            RouteTableId = Ref('rtTablePublic'),
            DestinationCidrBlock = '0.0.0.0/0',
            GatewayId = Ref('ig'),
            DependsOn = 'igAttach'
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPublic1Attach',
            SubnetId = Ref('PublicSubnet1'),
            RouteTableId = Ref('rtTablePublic')
        )
    )

    t.add_resource(
        kms.Key(
            'OpenEMRKey',
            DeletionPolicy = 'Retain',
            UpdateReplacePolicy = 'Retain',
            KeyPolicy = {
                "Version": "2012-10-17",
                "Id": "key-default-1",
                "Statement": [{
                    "Sid": "1",
                    "Effect": "Allow",
                    "Principal": {
                        "AWS": [
                            Join(':', ['arn:aws:iam:', ref_account, 'root'])
                        ]
                    },
                    "Action": "kms:*",
                    "Resource": "*"
                }]
            }
        )
    )

    t.add_resource(
        kms.Alias(
            'OpenEMRKeyAlias',
            DeletionPolicy = 'Retain',
            UpdateReplacePolicy = 'Retain',
            AliasName = Join('', ['alias/', ref_stack_name]),
            TargetKeyId = Ref('OpenEMRKey')
        )
    )

    t.add_resource(
        s3.Bucket(
            'S3Bucket',
            DeletionPolicy = 'Retain',
            BucketName = Join('-', ['openemr', Select('2', Split('/', ref_stack_id))])
        )
    )

    t.add_resource(
        s3.BucketPolicy(
            'BucketPolicy',
            Bucket = Ref('S3Bucket'),
            PolicyDocument = {
                "Version": "2012-10-17",
                "Statement": [
                    {
                      "Sid": "AWSCloudTrailAclCheck",
                      "Effect": "Allow",
                      "Principal": { "Service":"cloudtrail.amazonaws.com"},
                      "Action": "s3:GetBucketAcl",
                      "Resource": { "Fn::Join" : ["", ["arn:aws:s3:::", {"Ref":"S3Bucket"}]]}
                    },
                    {
                      "Sid": "AWSCloudTrailWrite",
                      "Effect": "Allow",
                      "Principal": { "Service":"cloudtrail.amazonaws.com"},
                      "Action": "s3:PutObject",
                      "Resource": { "Fn::Join" : ["", ["arn:aws:s3:::", {"Ref":"S3Bucket"}, "/AWSLogs/", {"Ref":"AWS::AccountId"}, "/*"]]},
                      "Condition": {
                        "StringEquals": {
                          "s3:x-amz-acl": "bucket-owner-full-control"
                        }
                      }
                    }
                ]
            }
        )
    )

    t.add_resource(
        cloudtrail.Trail(
            'CloudTrail',
            DependsOn = 'BucketPolicy',
            IsLogging = True,
            IncludeGlobalServiceEvents = True,
            IsMultiRegionTrail = True,
            S3BucketName = Ref('S3Bucket')
        )
    )

    return t

def buildInstance(t, args):
    t.add_resource(
        ec2.SecurityGroup(
            'WebserverSG',
            GroupDescription = 'Global Webserver Access',
            VpcId = Ref('VPC'),
            Tags = Tags(Name='Global Webserver Access')
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverSGIngress1',
            GroupId = Ref('WebserverSG'),
            IpProtocol = 'tcp',
            CidrIp = '0.0.0.0/0',
            FromPort = '22',
            ToPort = '22'
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverSGIngress2',
            GroupId = Ref('WebserverSG'),
            IpProtocol = 'tcp',
            CidrIp = '0.0.0.0/0',
            FromPort = '80',
            ToPort = '80'
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverSGIngress3',
            GroupId = Ref('WebserverSG'),
            IpProtocol = 'tcp',
            CidrIp = '0.0.0.0/0',
            FromPort = '443',
            ToPort = '443'
        )
    )

    rolePolicyStatements = [
        {
          "Sid": "SeeBuckets",
          "Effect": "Allow",
          "Action": ["s3:ListBucket"],
          "Resource" : [Join("", ["arn:aws:s3:::", Ref('S3Bucket')])]
        },
        {
            "Sid": "BucketRW",
            "Effect": "Allow",
            "Action": [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject"
            ],
            "Resource": [Join("", ["arn:aws:s3:::", Ref('S3Bucket'), '/Backup/*'])]
        },
        {
            "Sid": "KeyRW",
            "Effect": "Allow",
            "Action": [
              "kms:Encrypt",
              "kms:Decrypt",
              "kms:GenerateDataKey*"
            ],
            "Resource": [ OpenEMRKeyARN ]
        }
    ]

    if (args.recovery):
        rolePolicyStatements.extend([
            {
                "Sid": "SeeRecoveryBucket",
                "Effect": "Allow",
                "Action": ["s3:ListBucket"],
                "Resource": [Join("", ["arn:aws:s3:::", Ref('RecoveryS3Bucket')])]
            },
            {
                "Sid": "RecoveryBucketRead",
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                ],
                "Resource": [Join("", ["arn:aws:s3:::", Ref('RecoveryS3Bucket'), '/Backup/*'])]
            },
            {
                "Sid": "RecoveryKeyRead",
                "Effect": "Allow",
                "Action": [                
                    "kms:Decrypt"
                ],
                "Resource": [ Ref('RecoveryKMSKey') ]
            }
        ])

    t.add_resource(
        iam.ManagedPolicy(
            'WebserverPolicy',
            Description='Policy for webserver instance',
            PolicyDocument = {
                "Version": "2012-10-17",
                "Statement": rolePolicyStatements
            }
        )
    )

    t.add_resource(
        iam.Role(
            'WebserverRole',
            AssumeRolePolicyDocument = {
               "Version" : "2012-10-17",
               "Statement": [ {
                  "Effect": "Allow",
                  "Principal": {
                     "Service": [ "ec2.amazonaws.com" ]
                  },
                  "Action": [ "sts:AssumeRole" ]
               } ]
            },
            Path='/',
            ManagedPolicyArns= [Ref('WebserverPolicy')]
        )
    )

    t.add_resource(
        iam.InstanceProfile(
            'WebserverInstanceProfile',
            Path = '/',
            Roles = [Ref('WebserverRole')]
        )
    )

    t.add_resource(
        ec2.Volume(
            'DockerVolume',
            DeletionPolicy = 'Delete' if args.dev else 'Snapshot',
            Size=Ref('PracticeStorage'),
            AvailabilityZone = Select("0", GetAZs("")),
            VolumeType = 'gp3',
            Encrypted = True,
            KmsKeyId = OpenEMRKeyID,
            Tags=Tags(Name="OpenEMR Practice")
        )
    )

    bootstrapScript = [
        "#!/bin/bash -x\n",
        "exec > /tmp/part-001.log 2>&1\n",
        "apt-get -y update\n",
        "apt-get -y install python3-pip\n",
        "pip3 install --break-system-packages https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz\n",
        "ln -s /root/aws-cfn-bootstrap-latest/init/ubuntu/cfn-hup /etc/init.d/cfn-hup\n",
        "cfn-init -v ",
        "         --stack ", ref_stack_name,
        "         --resource WebserverInstance ",
        "         --configsets Setup ",
        "         --region ", ref_region, "\n",
        "cfn-signal -e $? ",
        "         --stack ", ref_stack_name,
        "         --resource WebserverInstance ",
        "         --region ", ref_region, "\n"
    ]

    setupScript = [
        "#!/bin/bash -xe\n",
        "exec > /tmp/cloud-setup.log 2>&1\n",

        "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\"\n",

        "DVOL_SERIAL=`echo ", Ref('DockerVolume'), " | sed s/-//`\n",
        "DVOL_DEVICE=/dev/`lsblk -no +SERIAL | grep $DVOL_SERIAL | awk '{print $1}'`\n",
        "mkfs -t ext4 $DVOL_DEVICE\n",        
        "echo $DVOL_DEVICE /mnt/docker ext4 defaults,nofail 0 0 >> /etc/fstab\n",
        "mkdir /mnt/docker\n",
        "mount /mnt/docker\n",
        "rm -rf /var/lib/docker /var/lib/containerd\n",
        "mkdir -p /mnt/docker/docker /mnt/docker/containerd\n",
        "ln -sfn /mnt/docker/docker /var/lib/docker\n",
        "ln -sfn /mnt/docker/containerd /var/lib/containerd\n",

        "apt-get -y install python3-boto3\n",
        "snap wait system seed.loaded\n",
        "snap install aws-cli --classic\n",
        "ln -sf /snap/bin/aws /usr/local/bin/aws\n",
        "source /root/cloud-variables\n",        
        "touch /root/cloud-backups-enabled\n",
        "echo $S3 > /root/.cloud-s3.txt\n",
        "echo $KMS > /root/.cloud-kms.txt\n",
        "touch /tmp/mypass\n",
        "chmod 500 /tmp/mypass\n",
        "openssl rand -base64 32 >> /tmp/mypass\n",
        "aws s3 cp /tmp/mypass s3://$S3/Backup/passphrase.txt --sse aws:kms --sse-kms-key-id $KMS\n",
        "rm /tmp/mypass\n"
    ]

    # this goes four ways, no help for it
    if (args.dev):
        scriptLine = [ "curl -L https://raw.githubusercontent.com/openemr/openemr-devops/", Ref('DeploymentBranch'), "/packages/appliance/launch.sh > /root/launch.sh\n"]
        if (args.recovery):
            launchLine = ["chmod +x /root/launch.sh && /root/launch.sh -b ", Ref('DeploymentBranch'), "\n"]
        else:
            launchLine = ["chmod +x /root/launch.sh && /root/launch.sh -b ", Ref('DeploymentBranch'), "\n"]
    else:
        scriptLine = [ "curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/appliance/launch.sh > /root/launch.sh\n" ]
        if (args.recovery):
            launchLine = ["chmod +x /root/launch.sh && /root/launch.sh\n"]
        else:
            launchLine = ["chmod +x /root/launch.sh && /root/launch.sh\n"]            
    setupScript.extend( scriptLine )            
    setupScript.extend( launchLine )   

    if (args.recovery):
        setupScript.extend([                        
            "touch /root/recovery-restore-required\n",
            "/root/openemr-devops/packages/appliance/restore.sh --confirm\n",
        ])    
    
    stackPassthroughFile = [
        "S3=", Ref('S3Bucket'), "\n",
        "KMS=", OpenEMRKeyID, "\n"
    ]

    if (args.recovery):
        stackPassthroughFile.extend([
            "RECOVERYS3=", Ref('RecoveryS3Bucket'), "\n",
            "RECOVERYKMS=", Ref('RecoveryKMSKey'), "\n",
        ])

    bootstrapInstall = cloudformation.InitConfig(
        files = {
            "/root/cloud-setup.sh" : {
                "content" : Join("", setupScript),
                "mode"  : "000500",
                "owner" : "root",
                "group" : "root"
            },
            "/root/cloud-variables": {
                "content": Join("", stackPassthroughFile),
                "mode": "000500",
                "owner": "root",
                "group": "root"
            },
        },
        commands = {
            "01_setup" : {
              "command" : "/root/cloud-setup.sh"
            }
        }
    )

    bootstrapMetadata = cloudformation.Metadata(
        cloudformation.Init(
            cloudformation.InitConfigSets(
                Setup = ['Install']
            ),
            Install=bootstrapInstall
        )
    )

    t.add_resource(
        ec2.Instance(
            'WebserverInstance',
            Metadata = bootstrapMetadata,
            ImageId = Ref('UbuntuAMI'),
            InstanceType = Ref('InstanceSize'),
            NetworkInterfaces = [ec2.NetworkInterfaceProperty(
                AssociatePublicIpAddress = True,
                DeviceIndex = "0",
                GroupSet = [ Ref('WebserverSG') ],
                SubnetId = Ref('PublicSubnet1')
            )],
            KeyName = Ref('EC2KeyPair'),
            IamInstanceProfile = Ref('WebserverInstanceProfile'),
            Volumes = [{
                "Device" : "/dev/sdd",
                "VolumeId" : Ref('DockerVolume')
            }],
            Tags = Tags(Name='OpenEMR Express Plus'),
            InstanceInitiatedShutdownBehavior = 'stop',
            UserData = Base64(Join('', bootstrapScript)),
            CreationPolicy = {
              "ResourceSignal" : {
                "Timeout" : "PT1H" if args.recovery else "PT40M"
              }
            }
        )
    )

    return t

def setOutputs(t, args):
    t.add_output(
        Output(
            'OpenEMR',
            Description='OpenEMR Setup',
            Value=Join('', ['https://', GetAtt('WebserverInstance', 'PublicIp')])
        )
    )
    return t

parser = argparse.ArgumentParser(description="OpenEMR Express Plus stack builder")
parser.add_argument("--dev", help="purge development resources on exit", action="store_true")
parser.add_argument("--recovery", help="load OpenEMR stack from backups", action="store_true")
args = parser.parse_args()

t = Template()

t.set_version('2010-09-09')
descString='OpenEMR Express Plus v8.2.0 cloud deployment'
if (args.dev):
    descString += ' [developer]'
if (args.recovery):
    descString += ' [recovery]'
t.set_description(descString)

# holdover from parent
OpenEMRKeyID = Ref('OpenEMRKey')
OpenEMRKeyARN = GetAtt('OpenEMRKey', 'Arn')

if (args.recovery):
    setRecoveryInputs(t, args)
else:
    setInputs(t, args)

if (args.dev):
    setDeveloperInputs(t, args)

setMappings(t,args)
buildInfrastructure(t, args)
buildInstance(t, args)
setOutputs(t, args)

print(t.to_json())
