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
        Description = 'EC2 instance size for tbe webserver (minimum t2.small recommended)',
        Default = 't2.small',
        Type = 'String',
        AllowedValues = [
            't2.micro', 't2.small', 't2.medium', 't2.large', 't2.xlarge', 't2.2xlarge'
        ]
    ))

    return t

def setMappings(t, args):
    t.add_mapping('RegionData', {
        "us-east-1" : {
            "UbuntuAMI": "ami-cd0f5cb6"
        },
        "us-east-2" : {
            "UbuntuAMI": "ami-10547475"
        },
        "us-west-1" : {
            "UbuntuAMI": "ami-09d2fb69"
        },
        "us-west-2" : {
            "UbuntuAMI": "ami-6e1a0117"
        },
        "ap-south-1" : {
            "UbuntuAMI": "ami-099fe766"
        },
        "ap-northeast-1" : {
            "UbuntuAMI": "ami-ea4eae8c"
        },
        "ap-northeast-2" : {
            "UbuntuAMI": "ami-d28a53bc"
        },
        "ap-southeast-1" : {
            "UbuntuAMI": "ami-6f198a0c"
        },
        "ap-southeast-2" : {
            "UbuntuAMI": "ami-e2021d81"
        },
        "sa-east-1" : {
            "UbuntuAMI": "ami-10186f7c"
        },
        "ca-central-1" : {
            "UbuntuAMI": "ami-b3d965d7"
        },
        "eu-central-1" : {
            "UbuntuAMI": "ami-1e339e71"
        },
        "eu-west-1" : {
            "UbuntuAMI": "ami-785db401"
        },
        "eu-west-2" : {
            "UbuntuAMI": "ami-996372fd"
        }
    })
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
            DeletionPolicy = 'Delete',
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
          "Sid": "Stmt1500699052003",
          "Effect": "Allow",
          "Action": ["s3:ListBucket"],
          "Resource" : [Join("", ["arn:aws:s3:::", Ref('S3Bucket')])]
        },
        {
            "Sid": "Stmt1500699052000",
            "Effect": "Allow",
            "Action": [
              "s3:PutObject",
              "s3:GetObject",
              "s3:DeleteObject"
            ],
            "Resource": [Join("", ["arn:aws:s3:::", Ref('S3Bucket'), '/Backup/*'])]
        },
        {
            "Sid": "Stmt1500612724002",
            "Effect": "Allow",
            "Action": [
              "kms:Encrypt",
              "kms:Decrypt",
              "kms:GenerateDataKey*"
            ],
            "Resource": [ OpenEMRKeyARN ]
        }
    ]

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
            VolumeType = 'gp2',
            Encrypted = True,
            KmsKeyId = OpenEMRKeyID,
            Tags=Tags(Name="OpenEMR Practice")
        )
    )

    bootstrapScript = [
        "#!/bin/bash -x\n",
        "exec > /tmp/part-001.log 2>&1\n",
        "apt-get -y update\n",
        "apt-get -y install python-pip\n",
        "pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz\n",
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

        "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" --force-yes\n",
        "mkfs -t ext4 /dev/xvdd\n",
        "mkdir /mnt/docker\n",
        "cat /root/fstab.append >> /etc/fstab\n",
        "mount /mnt/docker\n",
        "ln -s /mnt/docker /var/lib/docker\n",

        "apt-get -y install python-boto awscli\n",
        "S3=", Ref('S3Bucket'), "\n",
        "KMS=", OpenEMRKeyID, "\n",
        "touch /root/cloud-backups-enabled\n",
        "echo $S3 > /root/.cloud-s3.txt\n",
        "echo $KMS > /root/.cloud-kms.txt\n",
        "touch /tmp/mypass\n",
        "chmod 500 /tmp/mypass\n",
        "openssl rand -base64 32 >> /tmp/mypass\n",
        "aws s3 cp /tmp/mypass s3://$S3/Backup/passphrase.txt --sse aws:kms --sse-kms-key-id $KMS\n",
        "rm /tmp/mypass\n",

        "curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/packages/lightsail/launch.sh > /root/launch.sh\n",
        "chmod +x /root/launch.sh && /root/launch.sh -s 0\n"
    ]

    fstabFile = [
        "/dev/xvdd /mnt/docker ext4 defaults,nofail 0 0\n"
    ]

    bootstrapInstall = cloudformation.InitConfig(
        files = {
            "/root/cloud-setup.sh" : {
                "content" : Join("", setupScript),
                "mode"  : "000500",
                "owner" : "root",
                "group" : "root"
            },
            "/root/fstab.append" : {
                "content" : Join("", fstabFile),
                "mode"  : "000400",
                "owner" : "root",
                "group" : "root"
            }
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
            ImageId = FindInMap('RegionData', ref_region, 'UbuntuAMI'),
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
                "Timeout" : "PT25M"
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
            Value=Join('', ['http://', GetAtt('WebserverInstance', 'PublicIp')])
        )
    )
    return t

parser = argparse.ArgumentParser(description="OpenEMR Express Plus stack builder")
parser.add_argument("--dev", help="purge development resources on exit", action="store_true")
args = parser.parse_args()

t = Template()

t.add_version('2010-09-09')
descString='OpenEMR Express Plus v5.0.2 cloud deployment'
t.add_description(descString)

# holdover from parent
OpenEMRKeyID = Ref('OpenEMRKey')
OpenEMRKeyARN = GetAtt('OpenEMRKey', 'Arn')

setInputs(t,args)
setMappings(t,args)
buildInfrastructure(t, args)
buildInstance(t, args)
setOutputs(t, args)

print(t.to_json())
