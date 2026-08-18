# El caso mayoritario: una clave que delega integramente en IAM.
#
# Sin key_administrators, sin key_users y sin service_principals. El statement
# raiz hace todo el trabajo y las politicas IAM de la cuenta deciden quien
# puede usar la clave. Tres variables de entrada y ninguna decision de
# seguridad delegada en el consumidor: el default ES la politica.
#
# Los examples SI llevan bloque provider -son un root module- pero NO llevan
# backend: el estado es local y efimero.
#
#   terraform init
#   terraform plan
#
# Requiere credenciales de AWS: aws_caller_identity y aws_partition se leen de
# verdad durante el plan. No crea nada hasta el apply.

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
      Project = "PI-Modules"
      Example = "kms/minimal"
    }
  }
}

variable "region" {
  description = "Region donde se crea la clave. KMS es regional."
  type        = string
  default     = "us-east-1"
}

###############################################################################
# La invocacion
#
# name es el componente. locals.tf compone a partir de el:
#   tag Name -> dev-acme-app-kms
#   alias    -> alias/dev/acme-app
#
# Por eso name NO repite el entorno: quedaria dev-acme-dev-app-kms.
###############################################################################

module "kms" {
  source = "../../"

  name        = "acme-app"
  environment = "dev"
  description = "Cifrado en reposo de los datos de aplicacion del entorno dev"
}

###############################################################################
# Outputs
#
# La postura es lo que hay que mirar en el plan, no los identificadores: los
# ids son "(known after apply)" y no dicen nada. unscoped_service_principals
# debe salir vacio aqui, porque no hay ningun principal de servicio.
###############################################################################

output "alias_name" {
  description = "El identificador que se usa en la practica."
  value       = module.kms.alias_name
}

output "posture" {
  description = "Postura del modulo, evaluable en plan."
  value = {
    rotation_enabled            = module.kms.rotation_enabled
    multi_region                = module.kms.multi_region
    has_policy_override         = module.kms.has_policy_override
    key_administrators_count    = module.kms.key_administrators_count
    key_users_count             = module.kms.key_users_count
    unscoped_service_principals = module.kms.unscoped_service_principals
  }
}
