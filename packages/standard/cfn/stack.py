#!/usr/bin/python
# -*- coding: utf-8 -*-

# TODO: remove unneeded troposphere imports
# TODO: update docs to discuss admin SSH access
# TODO: rebuild AMI following pending reorg
# TODO: don't I need an essay thing somewhere in metadata?

from troposphere import Base64, FindInMap, GetAtt, GetAZs, Join, Select, Split, Output
from troposphere import Parameter, Ref, Tags, Template
from troposphere import ec2, route53, kms, s3, efs, elasticache, cloudtrail, rds, iam, cloudformation, awslambda, events, elasticbeanstalk

import argparse

ref_stack_id = Ref('AWS::StackId')
ref_region = Ref('AWS::Region')
ref_stack_name = Ref('AWS::StackName')
ref_account = Ref('AWS::AccountId')

docker_version = '@sha256:32a7d23eb8f663f012b27cf2189de4416eb00fc901ee918ffa9f2856b74d9fdf'

def setInputs(t, args):
    paramLabels = {}

    t.add_parameter(Parameter(
        'EC2KeyPair',
        Description = 'Amazon EC2 Key Pair',
        Type = 'AWS::EC2::KeyPair::KeyName'
    ))

    paramLabels["EC2KeyPair"] = { 'default': 'Your EC2 SSH key for connecting to OpenEMR''s shell.' }

    t.add_parameter(Parameter(
        'PracticeStorage',
        Description = 'Storage for the OpenEMR practice (minimum 10 GB)',
        Default = '10',
        Type = 'Number',
        MinValue = '10'
    ))

    paramLabels["PracticeStorage"] = { 'default': 'How much space should we reserve for patient documents?' }

    t.add_parameter(Parameter(
        'PatientRecords',
        Description = 'Database storage for patient records (minimum 10 GB)',
        Default = '10',
        Type = 'Number',
        MinValue = '10'
    ))

    paramLabels["PatientRecords"] = { 'default': 'How much database space should we reserve for patient records?' }

    t.add_parameter(Parameter(
        'WebserverInstanceSize',
        Description = 'EC2 instance size for the webserver',
        Default = 't2.small',
        Type = 'String',
        AllowedValues = [
            't2.small', 't2.medium', 't2.large', 't2.xlarge', 't2.2xlarge'
        ]
    ))

    paramLabels["WebserverInstanceSize"] = { 'default': 'What size webserver should we create in EC2?' }

    t.add_parameter(Parameter(
        'AdminPassword',
        NoEcho = True,
        Description = 'The OpenEMR admin account password',
        Type = 'String',
        MinLength = '8',
        MaxLength = '41'
    ))

    paramLabels["AdminPassword"] = { 'default': 'Pick a strong password for your OpenEMR administrator account.' }

    t.add_parameter(Parameter(
        'RDSInstanceSize',
        Description = 'RDS instance size for the back-end database',
        Default = 'db.t2.small',
        Type = 'String',
        AllowedValues = [
            'db.t2.micro', 'db.t2.small', 'db.t2.medium', 'db.t2.large', 'db.m4.large'
        ]
    ))

    paramLabels["RDSInstanceSize"] = { 'default': 'How powerful should our database be?' }

    t.add_parameter(Parameter(
        'RDSPassword',
        NoEcho = True,
        Description = 'The database admin account password',
        Type = 'String',
        MinLength = '8',
        MaxLength = '41'
    ))

    paramLabels["RDSPassword"] = { 'default': 'Pick a strong password for your MySQL administrator account.' }

    t.add_metadata({
        'AWS::CloudFormation::Interface': {
            'ParameterGroups': [
                {
                    'Label': {'default': 'Credentials and Passwords'},
                    'Parameters': ['AdminPassword', 'RDSPassword', 'EC2KeyPair']
                },
                {
                    'Label': {'default': 'Size and Capacity'},
                    'Parameters': ['WebserverInstanceSize', 'PracticeStorage', 'RDSInstanceSize', 'PatientRecords']
                },
            ],
            'ParameterLabels': paramLabels
        }
    })

    return t

def setMappings(t, args):
    t.add_mapping('RegionData', {
        "us-east-1" : {
            "OpenEMRMktPlaceAMI": "ami-9acf60e0",
            "MySQLVersion": "5.6.27"
        }
    })

    return t

def buildVPC(t, args):
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
        ec2.Subnet(
            'PrivateSubnet1',
            VpcId = Ref('VPC'),
            CidrBlock = '10.0.2.0/24',
            AvailabilityZone = Select("0", GetAZs(""))
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PublicSubnet2',
            VpcId = Ref('VPC'),
            CidrBlock = '10.0.3.0/24',
            AvailabilityZone = Select("1", GetAZs(""))
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PrivateSubnet2',
            VpcId = Ref('VPC'),
            CidrBlock = '10.0.4.0/24',
            AvailabilityZone = Select("1", GetAZs(""))
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
        ec2.SubnetRouteTableAssociation(
            'rtPublic2Attach',
            SubnetId = Ref('PublicSubnet2'),
            RouteTableId = Ref('rtTablePublic')
        )
    )


    t.add_resource(
        ec2.RouteTable(
            'rtTablePrivate',
            VpcId = Ref('VPC')
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPrivate1Attach',
            SubnetId = Ref('PrivateSubnet1'),
            RouteTableId = Ref('rtTablePrivate')
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPrivate2Attach',
            SubnetId = Ref('PrivateSubnet2'),
            RouteTableId = Ref('rtTablePrivate')
        )
    )

    return t

def buildInfrastructure(t, args):

    t.add_resource(
        kms.Key(
            'OpenEMRKey',
            DeletionPolicy = 'Delete' if args.dev else 'Retain',
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

    t.add_resource(
        ec2.SecurityGroup(
            'ApplicationSecurityGroup',
            GroupDescription = 'Application Security Group',
            VpcId = Ref('VPC'),
            Tags = Tags(Name='Application')
        )
    )

    return t

def buildMySQL(t, args):
    t.add_resource(
        ec2.SecurityGroup(
            'DBSecurityGroup',
            GroupDescription = 'Patient Records',
            VpcId = Ref('VPC'),
            Tags = Tags(Name='MySQL Access')
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'DBSGIngress',
            GroupId = Ref('DBSecurityGroup'),
            IpProtocol = '-1',
            SourceSecurityGroupId = Ref('ApplicationSecurityGroup')
        )
    )

    t.add_resource(
        rds.DBSubnetGroup(
            'RDSSubnetGroup',
            DBSubnetGroupDescription = 'MySQL node locations',
            SubnetIds = [Ref('PrivateSubnet1'), Ref('PrivateSubnet2')]
        )
    )

    t.add_resource(
        rds.DBInstance(
            'RDSInstance',
            DeletionPolicy = 'Delete' if args.dev else 'Snapshot',
            DBName = 'openemr',
            AllocatedStorage = Ref('PatientRecords'),
            DBInstanceClass = Ref('RDSInstanceSize'),
            Engine = 'MySQL',
            EngineVersion = FindInMap('RegionData', ref_region, 'MySQLVersion'),
            MasterUsername = 'openemr',
            MasterUserPassword = Ref('RDSPassword'),
            PubliclyAccessible = False,
            DBSubnetGroupName = Ref('RDSSubnetGroup'),
            VPCSecurityGroups = [Ref('DBSecurityGroup')],
            KmsKeyId = OpenEMRKeyID,
            StorageEncrypted = True,
            MultiAZ = True,
            Tags = Tags(Name='Patient Records')
        )
    )

    return t

def buildInstance(t, args):
    t.add_resource(
        ec2.SecurityGroup(
            'WebserverIngressSG',
            GroupDescription = 'Global Webserver Access',
            VpcId = Ref('VPC'),
            Tags = Tags(Name='Global Webserver Access')
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverIngressSG80',
            GroupId = Ref('WebserverIngressSG'),
            IpProtocol = 'tcp',
            CidrIp = '0.0.0.0/0',
            FromPort = '80',
            ToPort = '80'
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverIngress443',
            GroupId = Ref('WebserverIngressSG'),
            IpProtocol = 'tcp',
            CidrIp = '0.0.0.0/0',
            FromPort = '443',
            ToPort = '443'
        )
    )

    t.add_resource(
        ec2.SecurityGroup(
            'SysAdminAccessSG',
            GroupDescription = 'System Administrator Access',
            VpcId = Ref('VPC'),
            Tags = Tags(Name='System Administrator Access')
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
        "exec > /var/log/openemr-cfn-bootstrap 2>&1\n",
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
        "/root/openemr-devops/packages/standard/ami/ami-configure.sh\n"
    ]

    stackPassthroughFile = [
        "S3=", Ref('S3Bucket'), "\n",
        "KMS=", OpenEMRKeyID, "\n"
    ]

    dockerComposeFile = [
        "version: '3.1'\n",
        "services:\n",
        "  openemr:\n",
        "    restart: always\n",
        "    image: openemr/openemr", docker_version, "\n",
        "    ports:\n",
        "    - 80:80\n",
        "    - 443:443\n",
        "    volumes:\n",
        "    - logvolume01:/var/log\n",
        "    - sitevolume:/var/www/localhost/htdocs/openemr/sites/default\n",
        "    environment:\n",
        "      MYSQL_HOST: ", GetAtt('RDSInstance', 'Endpoint.Address'), "\n",
        "      MYSQL_ROOT_USER: openemr\n",
        "      MYSQL_ROOT_PASS: ", Ref('RDSPassword'), "\n",
        "      MYSQL_USER: openemr\n",
        "      MYSQL_PASS: ", Ref('RDSPassword'), "\n",
        "      OE_USER: admin\n",
        "      OE_PASS: ", Ref('AdminPassword'), "\n",
        "volumes:\n",
        "  logvolume01: {}\n",
        "  sitevolume: {}\n"
    ]

    bootstrapInstall = cloudformation.InitConfig(
        files = {
            "/root/cloud-setup.sh" : {
                "content" : Join("", setupScript),
                "mode"  : "000500",
                "owner" : "root",
                "group" : "root"
            },
            "/root/cloud-variables" : {
                "content" : Join("", stackPassthroughFile),
                "mode"  : "000500",
                "owner" : "root",
                "group" : "root"
            },
            "/root/openemr-devops/packages/standard/docker-compose.yaml" : {
                "content" : Join("", dockerComposeFile),
                "mode"  : "000500",
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
            ImageId = FindInMap('RegionData', ref_region, 'OpenEMRMktPlaceAMI'),
            InstanceType = Ref('WebserverInstanceSize'),
            NetworkInterfaces = [ec2.NetworkInterfaceProperty(
                AssociatePublicIpAddress = True,
                DeviceIndex = "0",
                GroupSet = [ Ref('ApplicationSecurityGroup'), Ref('WebserverIngressSG'), Ref('SysAdminAccessSG') ],
                SubnetId = Ref('PublicSubnet1')
            )],
            KeyName = Ref('EC2KeyPair'),
            IamInstanceProfile = Ref('WebserverInstanceProfile'),
            Volumes = [{
                "Device" : "/dev/sdd",
                "VolumeId" : Ref('DockerVolume')
            }],
            Tags = Tags(Name='OpenEMR Express'),
            InstanceInitiatedShutdownBehavior = 'stop',
            UserData = Base64(Join('', bootstrapScript)),
            CreationPolicy = {
              "ResourceSignal" : {
                "Timeout" : "PT15M"
              }
            }
        )
    )

    return t

def setOutputs(t, args):
    t.add_output(
        Output(
            'OpenEMRURL',
            Description='OpenEMR Installation',
            Value=Join('', ['http://', GetAtt('WebserverInstance', 'PublicIp'), '/'])
        )
    )

    return t

parser = argparse.ArgumentParser(description="OpenEMR Express stack builder")
parser.add_argument("--dev", help="purge development resources on exit", action="store_true")
args = parser.parse_args()

t = Template()

t.add_version('2010-09-09')
descString='OpenEMR Express v5.0.0.5 cloud deployment'
t.add_description(descString)

# holdover from parent
OpenEMRKeyID = Ref('OpenEMRKey')
OpenEMRKeyARN = GetAtt('OpenEMRKey', 'Arn')

setInputs(t,args)
setMappings(t,args)
buildVPC(t, args)
buildInfrastructure(t, args)
buildMySQL(t, args)
buildInstance(t, args)
setOutputs(t, args)

print(t.to_json())
