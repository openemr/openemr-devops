#!/usr/bin/python
# -*- coding: utf-8 -*-

# TODO: update docs to discuss admin SSH access

from troposphere import Base64, FindInMap, GetAtt, GetAZs, Join, Select, Split, Output
from troposphere import Parameter, Ref, Tags, Template
from troposphere import ec2, kms, s3, cloudtrail, rds, iam, cloudformation

import argparse

ref_stack_id = Ref('AWS::StackId')
ref_region = Ref('AWS::Region')
ref_stack_name = Ref('AWS::StackName')
ref_account = Ref('AWS::AccountId')

docker_version = ':7.0.2'


def setInputs(t, args):
    paramLabels = {}

    t.add_parameter(Parameter(
        'EC2KeyPair',
        Description='Amazon EC2 Key Pair',
        Type='AWS::EC2::KeyPair::KeyName'
    ))

    paramLabels["EC2KeyPair"] = {
        'default': 'Your EC2 SSH key for connecting to OpenEMR''s shell.'}

    t.add_parameter(Parameter(
        'PracticeStorage',
        Description='Storage for the OpenEMR practice (minimum 10 GB)',
        Default='10',
        Type='Number',
        MinValue='10'
    ))

    paramLabels["PracticeStorage"] = {
        'default': 'How much space should we reserve for patient documents?'}

    t.add_parameter(Parameter(
        'PatientRecords',
        Description='Database storage for patient records (minimum 10 GB)',
        Default='10',
        Type='Number',
        MinValue='10'
    ))

    paramLabels["PatientRecords"] = {
        'default': 'How much database space should we reserve for patient records?'}

    t.add_parameter(Parameter(
        'WebserverInstanceSize',
        Description='EC2 instance size for the webserver',
        Default='t3.small',
        Type='String',
        AllowedValues=[
            't3.small', 't3.medium', 't3.large', 't3.xlarge', 't3.2xlarge',
            'm6a.large', 'm6a.xlarge', 'm6a.2xlarge', 'm6a.4xlarge',
            'm6i.large', 'm6i.xlarge', 'm6i.2xlarge', 'm6i.4xlarge',
            'c6a.large', 'c6a.xlarge', 'c6a.2xlarge', 'c6a.4xlarge',
            'c6i.large', 'c6i.xlarge', 'c6i.2xlarge', 'c6i.4xlarge'
        ]
    ))

    paramLabels["WebserverInstanceSize"] = {
        'default': 'What size webserver should we create in EC2?'}

    t.add_parameter(Parameter(
        'AdminPassword',
        NoEcho=True,
        Description='The OpenEMR admin account password',
        Type='String',
        MinLength='8',
        AllowedPattern='[A-Za-z0-9/!@#%:_,\.\^\-\+]+',
        ConstraintDescription='password must contain only letters, numbers, and /!@#%:_,.^-+',
        MaxLength='41'
    ))

    paramLabels["AdminPassword"] = {
        'default': 'Pick a strong password for your OpenEMR administrator account.'}

    t.add_parameter(Parameter(
        'RDSInstanceSize',
        Description='RDS instance size for the back-end database',
        Default='db.t3.small',
        Type='String',
        AllowedValues=[
            'db.t3.small', 'db.t3.medium', 'db.t3.large', 'db.t3.xlarge', 'db.t3.2xlarge',
            'db.m5.large', 'db.m5.xlarge', 'db.m5.2xlarge', 'db.m5.4xlarge',
            'db.r5.large', 'db.r5.xlarge', 'db.r5.2xlarge', 'db.r5.4xlarge'
        ]
    ))

    paramLabels["RDSInstanceSize"] = {
        'default': 'How powerful should our database be?'}

    t.add_parameter(Parameter(
        'RDSPassword',
        NoEcho=True,
        Description='The database admin account password',
        Type='String',
        AllowedPattern='[A-Za-z0-9/!@#%:_,\.\^\-\+]+',
        ConstraintDescription='password must contain only letters, numbers, and /!@#%:_,.^-+',
        MinLength='8',
        MaxLength='41'
    ))

    paramLabels["RDSPassword"] = {
        'default': 'Pick a strong password for your MySQL administrator account.'}

    t.add_parameter(Parameter(
        'UserCidr',
        Description='VPC CIDR block',
        Default='10.0.0.0/16',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserCidr"] = {
        'default': 'Enter a valid CIDR for the OpenEMR VPC'}

    t.add_parameter(Parameter(
        'UserSubnetPublic1',
        Description='Public Subnet (AZ #1)',
        Default='10.0.1.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPublic1"] = {
        'default': 'Add the first public subnet to the VPC'}

    t.add_parameter(Parameter(
        'UserSubnetPrivate1',
        Description='Private Subnet (AZ #1)',
        Default='10.0.2.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPrivate1"] = {
        'default': 'Add the first private subnet to the VPC'}

    t.add_parameter(Parameter(
        'UserSubnetPublic2',
        Description='Public Subnet (AZ #2)',
        Default='10.0.3.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPublic2"] = {
        'default': 'Add the second public subnet to the VPC'}

    t.add_parameter(Parameter(
        'UserSubnetPrivate2',
        Description='Private Subnet (AZ #2)',
        Default='10.0.4.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPrivate2"] = {
        'default': 'Add the second private subnet to the VPC'}

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
                {
                    'Label': {'default': 'Network Settings'},
                    'Parameters': ['UserCidr', 'UserSubnetPublic1', 'UserSubnetPrivate1', 'UserSubnetPublic2', 'UserSubnetPrivate2']
                },
            ],
            'ParameterLabels': paramLabels
        }
    })

    return t


def setRecoveryInputs(t, args):
    paramLabels = {}

    t.add_parameter(Parameter(
        'EC2KeyPair',
        Description='Amazon EC2 Key Pair',
        Type='AWS::EC2::KeyPair::KeyName'
    ))

    paramLabels["EC2KeyPair"] = {
        'default': 'Your EC2 SSH key for connecting to OpenEMR''s shell.'}

    t.add_parameter(Parameter(
        'PracticeStorage',
        Description='Storage for the OpenEMR practice (minimum 10 GB)',
        Default='10',
        Type='Number',
        MinValue='10'
    ))

    paramLabels["PracticeStorage"] = {
        'default': 'How much space should we reserve for patient documents?'}

    t.add_parameter(Parameter(
        'WebserverInstanceSize',
        Description='EC2 instance size for the webserver',
        Default='t3.small',
        Type='String',
        AllowedValues=[
            't3.small', 't3.medium', 't3.large',
            'm6a.large', 'm6a.xlarge', 'm6i.large', 'm6i.xlarge'
        ]
    ))

    paramLabels["WebserverInstanceSize"] = {
        'default': 'What size webserver should we create in EC2?'}

    t.add_parameter(Parameter(
        'RDSInstanceSize',
        Description='RDS instance size for the back-end database',
        Default='db.t3.small',
        Type='String',
        AllowedValues=[
            'db.t3.micro', 'db.t3.small', 'db.t3.medium', 
            'db.m6g.large', 'db.m6g.xlarge',
            'db.r6g.large', 'db.r6g.xlarge', 'db.r6g.2xlarge'
        ]
    ))

    paramLabels["RDSInstanceSize"] = {
        'default': 'How powerful should our database be?'}

    t.add_parameter(Parameter(
        'RecoveryKMSKey',
        Description='KMS ARN ("arn:aws:kms...")',
        Type='String'
    ))

    paramLabels["RecoveryKMSKey"] = {
        'default': 'What KMS key was OpenEMR using?'}

    t.add_parameter(Parameter(
        'RecoveryRDSSnapshotARN',
        Description='RDS snapshot ARN ("arn:aws:rds...")',
        Type='String'
    ))

    paramLabels["RecoveryRDSSnapshotARN"] = {
        'default': 'What RDS snapshot should we recover from?'}

    t.add_parameter(Parameter(
        'RecoveryS3Bucket',
        Description='S3 bucket name',
        Type='String'
    ))

    paramLabels["RecoveryS3Bucket"] = {
        'default': 'What S3 bucket should we recover from?'}

    t.add_parameter(Parameter(
        'UserCidr',
        Description='VPC CIDR block',
        Default='10.0.0.0/16',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserCidr"] = {
        'default': 'Select a valid CIDR for the OpenEMR VPC'}

    t.add_parameter(Parameter(
        'UserSubnetPublic1',
        Description='Public Subnet (AZ #1)',
        Default='10.0.1.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPublic1"] = {
        'default': 'Select a valid CIDR for the first public subnet'}

    t.add_parameter(Parameter(
        'UserSubnetPrivate1',
        Description='Private Subnet (AZ #1)',
        Default='10.0.2.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPrivate1"] = {
        'default': 'Select a valid CIDR for the first private subnet'}

    t.add_parameter(Parameter(
        'UserSubnetPublic2',
        Description='Public Subnet (AZ #2)',
        Default='10.0.3.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPublic2"] = {
        'default': 'Select a valid CIDR for the second public subnet'}

    t.add_parameter(Parameter(
        'UserSubnetPrivate2',
        Description='Private Subnet (AZ #2)',
        Default='10.0.4.0/24',
        Type='String',
        AllowedPattern='[0-9/\.]+',
        ConstraintDescription='must be a valid CIDR'
    ))

    paramLabels["UserSubnetPrivate2"] = {
        'default': 'Select a valid CIDR for the second private subnet'}

    t.add_metadata({
        'AWS::CloudFormation::Interface': {
            'ParameterGroups': [
                {
                    'Label': {'default': 'Credentials and Passwords'},
                    'Parameters': ['EC2KeyPair']
                },

                {
                    'Label': {'default': 'Size and Capacity'},
                    'Parameters': ['WebserverInstanceSize', 'PracticeStorage', 'RDSInstanceSize', 'PatientRecords']
                },

                {
                    'Label': {'default': 'Stack Recovery'},
                    'Parameters': ['RecoveryKMSKey', 'RecoveryRDSSnapshotARN', 'RecoveryS3Bucket']
                },
                {
                    'Label': {'default': 'Network Settings'},
                    'Parameters': ['UserCidr', 'UserSubnetPublic1', 'UserSubnetPrivate1', 'UserSubnetPublic2', 'UserSubnetPrivate2']
                },
            ],
            'ParameterLabels': paramLabels
        }
    })

    return t


def setMappings(t, args):
    t.add_mapping('RegionData', {
        "ap-northeast-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-2086695f"
        },
        "ap-northeast-2": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-d04ce5be"
        },
        "ap-south-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-d2bd9dbd"
        },
        "ap-southeast-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-2fb49f53"
        },
        "ap-southeast-2": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-2a459148"
        },
        "ca-central-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-8de666e9"
        },
        "eu-central-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-b105265a"
        },
        "eu-west-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-dd99b2a4"
        },
        "eu-west-2": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-96da38f1"
        },
        "eu-west-3": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-6c902111"
        },
        "sa-east-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-56e5b73a"
        },
        "us-east-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-07124126f9225d337"
        },
        "us-east-2": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-f97f429c"
        },
        "us-west-1": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-f5d6c995"
        },
        "us-west-2": {
            "MySQLVersion": "8.0.36",
            "OpenEMRMktPlaceAMI": "ami-8b4d3af3"
        }
    })

    return t


def buildVPC(t, args):
    t.add_resource(
        ec2.VPC(
            'VPC',
            CidrBlock=Ref('UserCidr'),
            EnableDnsSupport='true',
            EnableDnsHostnames='true'
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PublicSubnet1',
            VpcId=Ref('VPC'),
            CidrBlock=Ref('UserSubnetPublic1'),
            AvailabilityZone=Select("0", GetAZs(""))
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PrivateSubnet1',
            VpcId=Ref('VPC'),
            CidrBlock=Ref('UserSubnetPrivate1'),
            AvailabilityZone=Select("0", GetAZs(""))
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PublicSubnet2',
            VpcId=Ref('VPC'),
            CidrBlock=Ref('UserSubnetPublic2'),
            AvailabilityZone=Select("1", GetAZs(""))
        )
    )

    t.add_resource(
        ec2.Subnet(
            'PrivateSubnet2',
            VpcId=Ref('VPC'),
            CidrBlock=Ref('UserSubnetPrivate2'),
            AvailabilityZone=Select("1", GetAZs(""))
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
            VpcId=Ref('VPC'),
            InternetGatewayId=Ref('ig')
        )
    )

    t.add_resource(
        ec2.RouteTable(
            'rtTablePublic',
            VpcId=Ref('VPC')
        )
    )

    t.add_resource(
        ec2.Route(
            'rtPublic',
            RouteTableId=Ref('rtTablePublic'),
            DestinationCidrBlock='0.0.0.0/0',
            GatewayId=Ref('ig'),
            DependsOn='igAttach'
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPublic1Attach',
            SubnetId=Ref('PublicSubnet1'),
            RouteTableId=Ref('rtTablePublic')
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPublic2Attach',
            SubnetId=Ref('PublicSubnet2'),
            RouteTableId=Ref('rtTablePublic')
        )
    )

    t.add_resource(
        ec2.RouteTable(
            'rtTablePrivate',
            VpcId=Ref('VPC')
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPrivate1Attach',
            SubnetId=Ref('PrivateSubnet1'),
            RouteTableId=Ref('rtTablePrivate')
        )
    )

    t.add_resource(
        ec2.SubnetRouteTableAssociation(
            'rtPrivate2Attach',
            SubnetId=Ref('PrivateSubnet2'),
            RouteTableId=Ref('rtTablePrivate')
        )
    )

    return t


def buildInfrastructure(t, args):

    if (not args.recovery):
        t.add_resource(
            kms.Key(
                'OpenEMRKey',
                DeletionPolicy='Retain' if args.recovery else 'Delete' if args.dev else 'Retain',
                KeyPolicy={
                    "Version": "2012-10-17",
                    "Id": "key-default-1",
                    "Statement": [{
                        "Sid": "1",
                        "Effect": "Allow",
                        "Principal": {
                            "AWS": [
                                Join(':', ['arn:aws:iam:',
                                           ref_account, 'root'])
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
            DeletionPolicy='Retain',
            BucketName=Join(
                '-', ['openemr', Select('2', Split('/', ref_stack_id))])
        )
    )

    t.add_resource(
        s3.BucketPolicy(
            'BucketPolicy',
            Bucket=Ref('S3Bucket'),
            PolicyDocument={
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Sid": "AWSCloudTrailAclCheck",
                        "Effect": "Allow",
                        "Principal": {"Service": "cloudtrail.amazonaws.com"},
                        "Action": "s3:GetBucketAcl",
                        "Resource": {"Fn::Join": ["", ["arn:aws:s3:::", {"Ref": "S3Bucket"}]]}
                    },
                    {
                        "Sid": "AWSCloudTrailWrite",
                        "Effect": "Allow",
                        "Principal": {"Service": "cloudtrail.amazonaws.com"},
                        "Action": "s3:PutObject",
                        "Resource": {"Fn::Join": ["", ["arn:aws:s3:::", {"Ref": "S3Bucket"}, "/AWSLogs/", {"Ref": "AWS::AccountId"}, "/*"]]},
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
            DependsOn='BucketPolicy',
            IsLogging=True,
            IncludeGlobalServiceEvents=True,
            IsMultiRegionTrail=True,
            S3BucketName=Ref('S3Bucket')
        )
    )

    t.add_resource(
        ec2.SecurityGroup(
            'ApplicationSecurityGroup',
            GroupDescription='Application Security Group',
            VpcId=Ref('VPC'),
            Tags=Tags(Name='Application')
        )
    )

    return t


def buildMySQL(t, args):
    t.add_resource(
        ec2.SecurityGroup(
            'DBSecurityGroup',
            GroupDescription='Patient Records',
            VpcId=Ref('VPC'),
            Tags=Tags(Name='MySQL Access')
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'DBSGIngress',
            GroupId=Ref('DBSecurityGroup'),
            IpProtocol='-1',
            SourceSecurityGroupId=Ref('ApplicationSecurityGroup')
        )
    )

    t.add_resource(
        rds.DBSubnetGroup(
            'RDSSubnetGroup',
            DBSubnetGroupDescription='MySQL node locations',
            SubnetIds=[Ref('PrivateSubnet1'), Ref('PrivateSubnet2')]
        )
    )

    if (args.recovery):
        t.add_resource(
            rds.DBInstance(
                'RDSInstance',
                DeletionPolicy='Delete' if args.dev else 'Snapshot',
                DBSnapshotIdentifier=Ref('RecoveryRDSSnapshotARN'),
                DBInstanceClass=Ref('RDSInstanceSize'),
                PubliclyAccessible=False,
                DBSubnetGroupName=Ref('RDSSubnetGroup'),
                VPCSecurityGroups=[Ref('DBSecurityGroup')],
                MultiAZ=not args.dev,
                Tags=Tags(Name='Patient Records')
            )
        )
    else:
        t.add_resource(
            rds.DBInstance(
                'RDSInstance',
                DeletionPolicy='Delete' if args.dev else 'Snapshot',
                DBName='openemr',
                AllocatedStorage=Ref('PatientRecords'),
                DBInstanceClass=Ref('RDSInstanceSize'),
                Engine='MySQL',
                EngineVersion=FindInMap(
                    'RegionData', ref_region, 'MySQLVersion'),
                MasterUsername='openemr',
                MasterUserPassword=Ref('RDSPassword'),
                PubliclyAccessible=False,
                DBSubnetGroupName=Ref('RDSSubnetGroup'),
                VPCSecurityGroups=[Ref('DBSecurityGroup')],
                KmsKeyId=OpenEMRKeyID,
                StorageEncrypted=True,
                MultiAZ=not args.dev,
                Tags=Tags(Name='Patient Records')
            )
        )

    return t


def buildInstance(t, args):
    t.add_resource(
        ec2.SecurityGroup(
            'WebserverIngressSG',
            GroupDescription='Global Webserver Access',
            VpcId=Ref('VPC'),
            Tags=Tags(Name='Global Webserver Access')
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverIngressSG80',
            GroupId=Ref('WebserverIngressSG'),
            IpProtocol='tcp',
            CidrIp='0.0.0.0/0',
            FromPort='80',
            ToPort='80'
        )
    )

    t.add_resource(
        ec2.SecurityGroupIngress(
            'WebserverIngress443',
            GroupId=Ref('WebserverIngressSG'),
            IpProtocol='tcp',
            CidrIp='0.0.0.0/0',
            FromPort='443',
            ToPort='443'
        )
    )

    t.add_resource(
        ec2.SecurityGroup(
            'SysAdminAccessSG',
            GroupDescription='System Administrator Access',
            VpcId=Ref('VPC'),
            Tags=Tags(Name='System Administrator Access')
        )
    )

    if (args.dev):
        t.add_resource(
            ec2.SecurityGroupIngress(
                'DevSysadminIngress22',
                GroupId=Ref('SysAdminAccessSG'),
                IpProtocol='tcp',
                CidrIp='0.0.0.0/0',
                FromPort='22',
                ToPort='22'
            )
        )

    rolePolicyStatements = [
        {
            "Sid": "Stmt1500699052003",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": [Join("", ["arn:aws:s3:::", Ref('S3Bucket')])]
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
            "Resource": [OpenEMRKeyARN]
        }
    ]

    if (args.recovery):
        rolePolicyStatements.extend([
            {
                "Sid": "Stmt1500699052004",
                "Effect": "Allow",
                "Action": ["s3:ListBucket"],
                "Resource": [Join("", ["arn:aws:s3:::", Ref('RecoveryS3Bucket')])]
            },
            {
                "Sid": "Stmt1500699052005",
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                ],
                "Resource": [Join("", ["arn:aws:s3:::", Ref('RecoveryS3Bucket'), '/Backup/*'])]
            },
        ])

    t.add_resource(
        iam.ManagedPolicy(
            'WebserverPolicy',
            Description='Policy for webserver instance',
            PolicyDocument={
                "Version": "2012-10-17",
                "Statement": rolePolicyStatements
            }
        )
    )

    t.add_resource(
        iam.Role(
            'WebserverRole',
            AssumeRolePolicyDocument={
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {
                        "Service": ["ec2.amazonaws.com"]
                    },
                    "Action": ["sts:AssumeRole"]
                }]
            },
            Path='/',
            ManagedPolicyArns=[Ref('WebserverPolicy')]
        )
    )

    t.add_resource(
        iam.InstanceProfile(
            'WebserverInstanceProfile',
            Path='/',
            Roles=[Ref('WebserverRole')]
        )
    )

    t.add_resource(
        ec2.Volume(
            'DockerVolume',
            DeletionPolicy='Delete' if args.dev else 'Snapshot',
            Size=Ref('PracticeStorage'),
            AvailabilityZone=Select("0", GetAZs("")),
            VolumeType='gp2',
            Encrypted=True,
            KmsKeyId=OpenEMRKeyID,
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
        "KMS=", OpenEMRKeyID, "\n",
        "DVOL=", Ref('DockerVolume') , "\n"
    ]

    if (args.recovery):
        stackPassthroughFile.extend([
            "RECOVERYS3=", Ref('RecoveryS3Bucket'), "\n",
            "RECOVERY_NEWRDS=", GetAtt(
                'RDSInstance', 'Endpoint.Address'), "\n",
        ])

    if (args.recovery):
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
            "    - sitevolume:/var/www/localhost/htdocs/openemr/sites\n",
            "    environment:\n",
            "      MANUAL_SETUP: 1\n",
            "      OPENEMR_DOCKER_ENV_TAG: aws-standard\n",
            "volumes:\n",
            "  logvolume01: {}\n",
            "  sitevolume: {}\n"
        ]
    else:
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
            "    - sitevolume:/var/www/localhost/htdocs/openemr/sites\n",
            "    environment:\n",
            "      MYSQL_HOST: '", GetAtt('RDSInstance', 'Endpoint.Address'), "'\n",
            "      MYSQL_ROOT_USER: openemr\n",
            "      MYSQL_ROOT_PASS: '", Ref('RDSPassword'), "'\n",
            "      MYSQL_USER: openemr\n",
            "      MYSQL_PASS: '", Ref('RDSPassword'), "'\n",
            "      OE_USER: admin\n",
            "      OE_PASS: '", Ref('AdminPassword'), "'\n",
            "      OPENEMR_DOCKER_ENV_TAG: aws-standard\n",
            "volumes:\n",
            "  logvolume01: {}\n",
            "  sitevolume: {}\n"
        ]

    bootstrapInstall = cloudformation.InitConfig(
        files={
            "/root/cloud-setup.sh": {
                "content": Join("", setupScript),
                "mode": "000500",
                "owner": "root",
                "group": "root"
            },
            "/root/cloud-variables": {
                "content": Join("", stackPassthroughFile),
                "mode": "000500",
                "owner": "root",
                "group": "root"
            },
            "/root/openemr-devops/packages/standard/docker-compose.yaml": {
                "content": Join("", dockerComposeFile),
                "mode": "000500",
                "owner": "root",
                "group": "root"
            }
        },
        commands={
            "01_setup": {
                "command": "/root/cloud-setup.sh"
            }
        }
    )

    bootstrapMetadata = cloudformation.Metadata(
        cloudformation.Init(
            cloudformation.InitConfigSets(
                Setup=['Install']
            ),
            Install=bootstrapInstall
        )
    )

    t.add_resource(
        ec2.Instance(
            'WebserverInstance',
            Metadata=bootstrapMetadata,
            ImageId=FindInMap('RegionData', ref_region, 'OpenEMRMktPlaceAMI'),
            InstanceType=Ref('WebserverInstanceSize'),
            NetworkInterfaces=[ec2.NetworkInterfaceProperty(
                AssociatePublicIpAddress=True,
                DeviceIndex="0",
                GroupSet=[Ref('ApplicationSecurityGroup'), Ref(
                    'WebserverIngressSG'), Ref('SysAdminAccessSG')],
                SubnetId=Ref('PublicSubnet1')
            )],
            KeyName=Ref('EC2KeyPair'),
            IamInstanceProfile=Ref('WebserverInstanceProfile'),
            Volumes=[{
                "Device": "/dev/sdd",
                "VolumeId": Ref('DockerVolume')
            }],
            Tags=Tags(Name='OpenEMR Cloud Standard'),
            InstanceInitiatedShutdownBehavior='stop',
            UserData=Base64(Join('', bootstrapScript)),
            CreationPolicy={
                "ResourceSignal": {
                    "Timeout": "PT15M"
                }
            }
        )
    )

    return t


def setOutputs(t, args):
    if (args.recovery):
        t.add_output(
            Output(
                'OpenEMRURL',
                Description='OpenEMR Recovery',
                Value=Join(
                    '', ['http://', GetAtt('WebserverInstance', 'PublicIp'), '/'])
            )
        )
    else:
        t.add_output(
            Output(
                'OpenEMRURL',
                Description='OpenEMR Installation',
                Value=Join(
                    '', ['http://', GetAtt('WebserverInstance', 'PublicIp'), '/'])
            )
        )

    return t


parser = argparse.ArgumentParser(description="OpenEMR Standard stack builder")
parser.add_argument(
    "--recovery", help="load OpenEMR stack from backups", action="store_true")
parser.add_argument(
    "--dev", help="purge development resources on exit", action="store_true")
args = parser.parse_args()

t = Template()

t.add_version('2010-09-09')
descString = 'OpenEMR Cloud Standard v7.0.2 cloud deployment'
if (args.dev):
    descString += ' [developer]'
if (args.recovery):
    descString += ' [recovery]'
t.add_description(descString)

# reduce to consistent names
if (args.recovery):
    OpenEMRKeyID = Select('1', Split('/', Ref('RecoveryKMSKey')))
    OpenEMRKeyARN = Ref('RecoveryKMSKey')
else:
    OpenEMRKeyID = Ref('OpenEMRKey')
    OpenEMRKeyARN = GetAtt('OpenEMRKey', 'Arn')

if (args.recovery):
    setRecoveryInputs(t, args)
else:
    setInputs(t, args)

setMappings(t, args)
buildVPC(t, args)
buildInfrastructure(t, args)
buildMySQL(t, args)
buildInstance(t, args)
setOutputs(t, args)

print(t.to_json())
