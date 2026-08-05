###############################################################################
# Minimal example - smoke test.
#
# The smallest input set that produces a usable, production-shaped VPC.
# Everything not set here is a module default, so this example doubles as the
# documentation of what "sensible defaults" actually means.
#
#   terraform init && terraform plan
###############################################################################

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
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
    }
  }
}

module "vpc" {
  source = "../.."

  name        = "demo-dev"
  environment = "dev"

  vpc_cidr           = "10.10.0.0/16"
  availability_zones = ["${var.region}a", "${var.region}b"]

  # Non-production: one NAT instead of one per AZ saves ~32 USD/month.
  nat_gateway_mode = "single"

  tags = {
    Project = "platform-demo"
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
  description = "Private subnet IDs, ready to be fed into a compute module."
  value       = module.vpc.private_subnet_ids
}
