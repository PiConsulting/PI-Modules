###############################################################################
# Ejemplo minimo - smoke test.
#
# Un solo security group con reglas por CIDR. Desacoplado a proposito: recibe
# el vpc_id por variable en vez de crear una VPC, para que el CI de este modulo
# no dependa del modulo vpc.
#
#   terraform init -backend=false && terraform validate
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
      Owner      = "plataforma@consultora.com"
      CostCenter = "CC-0001"
    }
  }
}

module "sg_alb" {
  source = "../.."

  name        = "demo-dev-alb"
  environment = "dev"
  vpc_id      = var.vpc_id
  description = "Balanceador publico del entorno de demostracion"

  ingress_rules = {
    "https-internet" = {
      description = "HTTPS desde internet"
      from_port   = 443
      to_port     = 443
      cidr_blocks = ["0.0.0.0/0"]
    }
    "http-redirect" = {
      description = "HTTP, unicamente para redirigir a HTTPS"
      from_port   = 80
      to_port     = 80
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = {
    Project = "platform-demo"
  }
}

variable "region" {
  description = "Region de AWS donde se despliega el ejemplo."
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID de una VPC existente. Se pasa por variable para no acoplar el CI de este modulo al modulo vpc."
  type        = string
  default     = "vpc-0123456789abcdef0"
}

output "security_group_id" {
  description = "ID del security group creado."
  value       = module.sg_alb.id
}

output "ingress_rule_ids" {
  description = "IDs de las reglas de entrada. Dos entradas del mapa con un CIDR cada una producen dos recursos."
  value       = module.sg_alb.ingress_rule_ids
}