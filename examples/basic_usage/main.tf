provider "aws" {
  profile = "cool-sharedservices-provisionaccount"
  region  = "us-east-1"
}

provider "aws" {
  alias   = "public_dns"
  profile = "cool-olddns-route53fullaccess"
  region  = "us-east-1"
}

provider "aws" {
  alias   = "cert_read_role"
  profile = "cool-dns-provisioncertificatereadroles"
  region  = "us-east-1"
}

#-------------------------------------------------------------------------------
# Create two subnets inside a VPC.
#-------------------------------------------------------------------------------
resource "aws_vpc" "the_vpc" {
  cidr_block           = "10.99.48.0/23"
  enable_dns_hostnames = true
}

resource "aws_subnet" "master_subnet" {
  vpc_id            = aws_vpc.the_vpc.id
  cidr_block        = "10.99.48.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "replica_subnet" {
  vpc_id            = aws_vpc.the_vpc.id
  cidr_block        = "10.99.49.0/24"
  availability_zone = "us-east-1b"
}

#-------------------------------------------------------------------------------
# Set up external access and routing in the VPC.
#-------------------------------------------------------------------------------

# The internet gateway for the VPC
resource "aws_internet_gateway" "the_igw" {
  vpc_id = aws_vpc.the_vpc.id
}

# Default route table
resource "aws_default_route_table" "the_route_table" {
  default_route_table_id = aws_vpc.the_vpc.default_route_table_id
}

# Route all external traffic through the internet gateway
resource "aws_route" "route_external_traffic_through_internet_gateway" {
  route_table_id         = aws_default_route_table.the_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.the_igw.id
}

#-------------------------------------------------------------------------------
# Create a private Route53 zone.
#-------------------------------------------------------------------------------
resource "aws_route53_zone" "private_zone" {
  name = "cyber.dhs.gov"

  vpc {
    vpc_id = aws_vpc.the_vpc.id
  }
}

#-------------------------------------------------------------------------------
# Create private Route53 reverse zones.
#-------------------------------------------------------------------------------
resource "aws_route53_zone" "master_private_reverse_zone" {
  name = "48.99.10.in-addr.arpa"

  vpc {
    vpc_id = aws_vpc.the_vpc.id
  }
}

resource "aws_route53_zone" "replica_private_reverse_zone" {
  name = "49.99.10.in-addr.arpa"

  vpc {
    vpc_id = aws_vpc.the_vpc.id
  }
}

#-------------------------------------------------------------------------------
# Create a data resource for the existing public Route53 zone.
#-------------------------------------------------------------------------------
data "aws_route53_zone" "public_zone" {
  provider = aws.public_dns

  name = "cyber.dhs.gov."
}

#-------------------------------------------------------------------------------
# Create roles that allows the master and replica to read their certs
# from S3.
# -------------------------------------------------------------------------------
data "aws_caller_identity" "shared_services" {
}

module "certreadrole_master" {
  source = "github.com/cisagov/cert-read-role-tf-module"

  providers = {
    aws = aws.cert_read_role
  }

  account_ids = [
    data.aws_caller_identity.shared_services.account_id,
  ]
  cert_bucket_name = "cisa-cool-certificates"
  hostname         = "ipa.cal23.cyber.dhs.gov"
}

module "certreadrole_replica" {
  source = "github.com/cisagov/cert-read-role-tf-module"

  providers = {
    aws = aws.cert_read_role
  }

  account_ids = [
    data.aws_caller_identity.shared_services.account_id,
  ]
  cert_bucket_name = "cisa-cool-certificates"
  hostname         = "ipa-replica1.cal23.cyber.dhs.gov"
}

#-------------------------------------------------------------------------------
# Configure the master and replica modules.
#-------------------------------------------------------------------------------
module "ipa_master" {
  source = "github.com/cisagov/freeipa-master-tf-module"

  providers = {
    aws            = aws
    aws.public_dns = aws.public_dns
  }

  admin_pw                    = var.admin_pw
  ami_owner_account_id        = "207871073513" # The COOL Images account
  associate_public_ip_address = true
  cert_bucket_name            = "cisa-cool-certificates"
  cert_pw                     = "lemmy"
  cert_read_role_arn          = module.certreadrole_master.role.arn
  directory_service_pw        = "thepassword"
  domain                      = "cal23.cyber.dhs.gov"
  hostname                    = "ipa.cal23.cyber.dhs.gov"
  private_reverse_zone_id     = aws_route53_zone.master_private_reverse_zone.zone_id
  private_zone_id             = aws_route53_zone.private_zone.zone_id
  public_zone_id              = data.aws_route53_zone.public_zone.zone_id
  realm                       = "CAL23.CYBER.DHS.GOV"
  subnet_id                   = aws_subnet.master_subnet.id
  tags = {
    Testing = true
  }
  trusted_cidr_blocks = var.trusted_cidr_blocks
  ttl                 = 60
}

module "ipa_replica1" {
  source = "../../"

  providers = {
    aws            = aws
    aws.public_dns = aws.public_dns
  }

  admin_pw                    = var.admin_pw
  ami_owner_account_id        = "207871073513" # The COOL Images account
  associate_public_ip_address = true
  cert_bucket_name            = "cisa-cool-certificates"
  cert_pw                     = "lemmy"
  cert_read_role_arn          = module.certreadrole_replica.role.arn
  hostname                    = "ipa-replica1.cal23.cyber.dhs.gov"
  master_hostname             = "ipa.cal23.cyber.dhs.gov"
  private_reverse_zone_id     = aws_route53_zone.replica_private_reverse_zone.zone_id
  private_zone_id             = aws_route53_zone.private_zone.zone_id
  public_zone_id              = data.aws_route53_zone.public_zone.zone_id
  server_security_group_id    = module.ipa_master.server_security_group.id
  subnet_id                   = aws_subnet.replica_subnet.id
  tags = {
    Testing = true
  }
  ttl = 60
}
