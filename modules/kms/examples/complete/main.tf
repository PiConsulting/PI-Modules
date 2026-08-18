###############################################################################
#
# Ejercita el contrato entero. Es el ejemplo que de verdad valida el modulo:
# minimal solo demuestra que el camino feliz compila.
#
# Lo que fuerza, en concreto:
#
#   - concat HETEROGENEO de local.policy_statements. La politica pasa de 1 a 6
#     statements y las listas de condiciones tienen longitudes 0, 0, 0, 1, 2 y 3.
#     Esa es la forma exacta del bug de tipos de iam-role, y en minimal no se
#     toca porque todos los grupos opcionales quedan vacios.
#   - key_users generando SUS DOS statements (cripto + grants).
#   - Dos principales de servicio con condiciones de tipo distinto:
#     encryption_context en uno, via_service + source_arn en el otro.
#   - El escape aditivo, comprobando que el statement raiz sobrevive.
#   - for_each de additional_aliases.
#   - multi_region.
#
# AVISO DE COSTE: esto crea una clave KMS real, ~1 USD/mes. Leer la nota de
# limpieza al final del archivo ANTES de hacer destroy.
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
      Project = "PI-Modules"
      Example = "kms/complete"
    }
  }
}

variable "region" {
  description = "Region donde se crea la clave. KMS es regional."
  type        = string
  default     = "us-east-1"
}

variable "partner_account_id" {
  description = <<-EOT
    Cuenta del tercero para el statement cross-account del escape.

    Por defecto apunta a TU PROPIA cuenta para que el ejemplo aplique sin
    depender de nadie. En un caso real es la cuenta del partner.

    Importante: KMS VALIDA que los principales de una key policy existan y
    rechaza el apply con MalformedPolicyDocumentException si no. Es la
    diferencia con una politica IAM adjunta a un rol, que no valida nada. Por
    eso este ejemplo crea sus propios roles en lugar de inventar ARNs.
  EOT
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partner    = coalesce(var.partner_account_id, local.account_id)
  prefix     = "acme-prod"
}

###############################################################################
# Principales de prueba
#
# Roles reales y gratuitos, creados aqui y no con el modulo iam-role: un
# example no debe acoplarse al tag de otro modulo del catalogo.
#
# Existen porque KMS valida los principales. Un ARN inventado no falla en plan,
# falla en apply, que es el peor momento posible.
###############################################################################

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "security_admin" {
  name               = "${local.prefix}-security-admin"
  description        = "Rol de prueba: administra el ciclo de vida de la clave, sin operaciones criptograficas"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role" "app_task" {
  name               = "${local.prefix}-app-task"
  description        = "Rol de prueba: usa la clave para cifrar y descifrar"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.prefix}-rds-monitoring"
  description        = "Rol de prueba: segundo usuario de la clave"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

###############################################################################
# El escape
#
# NO es JSON escrito a mano: es el .json del mismo aws_iam_policy_document,
# construido aqui, donde vive el conocimiento del negocio.
#
# Lleva Condition a proposito. Sin ella, la precondition #3 del modulo lo
# rechazaria si el principal fuera comodin; y sin Sid propio chocaria con los
# reservados y disparia la #1.
###############################################################################

data "aws_iam_policy_document" "partner" {
  statement {
    sid    = "PartnerAnalyticsDecrypt"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.partner}:root"]
    }

    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:tenant"
      values   = ["acme"]
    }
  }
}

###############################################################################
# La invocacion
###############################################################################

module "kms" {
  source = "../../"

  name        = "acme-data"
  environment = "prod"
  description = "Cifrado de datos de cliente: RDS, S3 y secretos del entorno prod"

  multi_region = true

  # 7 y no el default de 30 PORQUE ESTO ES UN LABORATORIO. Una clave en
  # PendingDeletion se sigue facturando: con 30 dias, cada iteracion de
  # apply/destroy deja ~1 USD corriendo un mes entero.
  # En prod se deja el default.
  deletion_window_in_days = 7

  additional_aliases = ["acme-data-legacy"]

  # Administracion: ciclo de vida, sin cripto y sin CreateGrant.
  key_administrators = [
    aws_iam_role.security_admin.arn,
  ]

  # Uso: genera DOS statements, el criptografico y el de grants.
  key_users = [
    aws_iam_role.app_task.arn,
    aws_iam_role.rds_monitoring.arn,
  ]

  service_principals = {
    # Principal REGIONAL. logs.amazonaws.com no falla: simplemente no concede
    # nada, que es peor. Condiciones resultantes: SourceAccount + 1 contexto.
    "logs.${var.region}.amazonaws.com" = {
      encryption_context = {
        "aws:logs:arn" = "arn:aws:logs:${var.region}:${local.account_id}:log-group:*"
      }
    }

    # Condiciones resultantes: SourceAccount + ViaService + SourceArn.
    "s3.amazonaws.com" = {
      via_service = ["s3.${var.region}.amazonaws.com"]
      source_arns = ["arn:aws:s3:::${local.prefix}-data"]
    }
  }

  extra_policy_json = data.aws_iam_policy_document.partner.json
}

###############################################################################
# Outputs
#
# La politica completa es lo que hay que leer en el plan. Debe tener SEIS
# statements y el primero tiene que ser EnableIAMUserPermissions: si el escape
# hubiera pisado el statement raiz, se veria aqui.
###############################################################################

output "alias_name" {
  value = module.kms.alias_name
}

output "additional_alias_names" {
  value = module.kms.additional_alias_names
}

output "posture" {
  description = "Postura del modulo, evaluable en plan."
  value = {
    rotation_enabled            = module.kms.rotation_enabled
    rotation_period_in_days     = module.kms.rotation_period_in_days
    multi_region                = module.kms.multi_region
    has_policy_override         = module.kms.has_policy_override
    key_administrators_count    = module.kms.key_administrators_count
    key_users_count             = module.kms.key_users_count
    service_principals_count    = module.kms.service_principals_count
    unscoped_service_principals = module.kms.unscoped_service_principals
  }
}

###############################################################################
# LIMPIEZA DESPUES DEL DESTROY
#
# terraform destroy NO borra la clave: la deja en PendingDeletion, y una clave
# en PendingDeletion SE SIGUE FACTURANDO hasta que se borra de verdad.
#
# Con deletion_window_in_days = 7 el coste maximo por iteracion es de una
# semana. Si aun asi quieres cortarlo, la ventana minima es 7 y no se puede
# bajar mas: no existe forma de borrar una clave KMS de inmediato.
#
#   aws kms describe-key --key-id <key_id> --query 'KeyMetadata.[KeyState,DeletionDate]'
#
# Para RECUPERAR una clave borrada por error, mientras dure la ventana:
#
#   aws kms cancel-key-deletion --key-id <key_id>
###############################################################################