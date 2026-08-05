###############################################################################
# Complete example - integration test.
#
# Every feature of the module turned on: 3 AZs, one NAT per AZ, explicit CIDRs,
# secondary CIDR range, gateway + interface endpoints, and flow logs with a
# customer-managed KMS key.
#
# This is the shape of a production deployment.
###############################################################################

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = "platform-demo"
      Owner      = "platform@consultora.com"
      CostCenter = "CC-0001"
      Repository = "github.com/consultora/tf-modules-pi"
    }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# KMS key for the flow logs log group.
# In a real deployment this comes from the security/kms module, not from here.
###############################################################################

resource "aws_kms_key" "logs" {
  description             = "CMK for VPC flow logs (example)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.kms_logs.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/demo-prod-flow-logs"
  target_key_id = aws_kms_key.logs.key_id
}

data "aws_iam_policy_document" "kms_logs" {
  statement {
    sid       = "AllowAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
  }
}

###############################################################################
# VPC
###############################################################################

module "vpc" {
  source = "../.."

  name        = "demo-prod"
  environment = "prod"

  vpc_cidr              = "10.20.0.0/16"
  secondary_cidr_blocks = ["10.21.0.0/16"]

  availability_zones = [
    "${var.region}a",
    "${var.region}b",
    "${var.region}c",
  ]

  # Explicit CIDRs: production address plans should be reviewable in a PR, not
  # derived from a formula that changes if someone tunes subnet_newbits.
  public_subnet_cidrs   = ["10.20.0.0/20", "10.20.16.0/20", "10.20.32.0/20"]
  private_subnet_cidrs  = ["10.20.64.0/20", "10.20.80.0/20", "10.20.96.0/20"]
  database_subnet_cidrs = ["10.20.128.0/22", "10.20.132.0/22", "10.20.136.0/22"]

  # Production egress: one NAT per AZ so a single AZ failure does not take
  # outbound connectivity down with it.
  nat_gateway_mode = "one_per_az"

  # Data tier stays isolated - no default route to the internet at all.
  database_subnets_route_to_nat = false

  enable_s3_endpoint       = true
  enable_dynamodb_endpoint = true

  interface_endpoint_services = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "ssm",
    "sts",
  ]

  enable_flow_logs                   = true
  flow_logs_destination_type         = "cloud-watch-logs"
  flow_logs_traffic_type             = "ALL"
  flow_logs_retention_days           = 365
  flow_logs_max_aggregation_interval = 60
  flow_logs_kms_key_arn              = aws_kms_key.logs.arn

  manage_default_security_group = true

  tags = {
    Project    = "platform-demo"
    Compliance = "pci-scope"
    DataClass  = "confidential"
  }

  # Discovery tags for load balancer controllers, added at the tier level.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

variable "region" {
  description = "AWS region to deploy the example into."
  type        = string
  default     = "us-east-1"
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = module.vpc.private_subnet_ids
}

output "database_subnet_group_name" {
  description = "DB subnet group name to feed into the RDS module."
  value       = module.vpc.database_subnet_group_name
}

output "nat_gateway_public_ips" {
  description = "Egress IPs to hand over for third-party allowlisting."
  value       = module.vpc.nat_gateway_public_ips
}
