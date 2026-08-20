# El caso mayoritario: un bucket generico con solo los dos inputs obligatorios.
#
# Sin kms_key_arn: cae automaticamente a SSE-S3 (AES256), nunca sin cifrar.
# Sin logging, sin lifecycle, sin custom_bucket_policy: todo lo demas usa su
# default. Versioning, TLS-only, Object Ownership BucketOwnerEnforced y el
# Public Access Block (4 protecciones) se aplican siempre, sin variable.
#
# Los examples SI llevan bloque provider -son un root module- pero NO llevan
# backend: el estado es local y efimero.
#
#   terraform init
#   terraform plan
#
# random_id resuelve la unicidad GLOBAL del nombre solo para que este example
# se pueda aplicar mas de una vez sin colisionar. El modulo en si NO compone
# el nombre (ver la decision de bucket_name en variables.tf): en un caso real,
# el consumidor elige el nombre final.

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0, < 4.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "PI-Modules"
      Example = "s3/minimal"
    }
  }
}

variable "region" {
  description = "Region donde se crea el bucket."
  type        = string
  default     = "us-east-1"
}

resource "random_id" "suffix" {
  byte_length = 4
}

###############################################################################
# La invocacion
###############################################################################

module "s3" {
  source = "../../"

  bucket_name = "pi-modules-s3-minimal-${random_id.suffix.hex}"
  environment = "dev"
}

###############################################################################
# Outputs
#
# La postura es lo que hay que mirar en el plan: sse_algorithm tiene que salir
# AES256 (no se paso kms_key_arn) y versioning_enabled siempre true.
###############################################################################

output "bucket_id" {
  value = module.s3.bucket_id
}

output "posture" {
  description = "Postura del modulo, evaluable en plan."
  value = {
    sse_algorithm      = module.s3.sse_algorithm
    versioning_enabled = module.s3.versioning_enabled
    has_custom_policy  = module.s3.has_custom_policy
  }
}