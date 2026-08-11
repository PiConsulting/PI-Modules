###############################################################################
# Ejemplo completo - integracion.
#
# Tres roles que cubren los tres patrones reales del catalogo:
#
#   1. Rol de servicio (tareas ECS) con politicas propias y gestionadas
#   2. Rol cross-account con ExternalId obligatorio
#   3. Rol de EC2 con instance profile
#
# Y la politica de permissions boundary que los tres comparten, que es el
# camino recomendado frente a la exencion de examples/minimal.
#
# Todo lo que crea este ejemplo es GRATIS: IAM no factura.
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
      Project = "platform-demo"
    }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# Permissions boundary
#
# El modulo NO crea esta politica: recibe su ARN. En un despliegue real sale
# del equipo de seguridad o del modulo iam-policy, y vive en una capa global
# porque IAM no tiene region.
#
# El Allow es amplio A PROPOSITO. Un boundary no concede permisos: es un techo,
# y el permiso efectivo sigue siendo la interseccion con la politica del rol.
# Con un Allow estrecho, el boundary anula en silencio todo lo que el rol
# conceda fuera de esa lista: el apply pasa y la aplicacion da AccessDenied sin
# que nada lo explique.
#
# Nota: esta politica no pasaria por el propio modulo iam-role, porque su
# precondition rechaza Action '*' sobre Resource '*'. Es correcto - un boundary
# es la excepcion legitima a esa regla, y por eso se crea fuera.
###############################################################################

data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "AllowAllExceptDenied"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid       = "DenyPrivilegeEscalation"
    effect    = "Deny"
    actions   = ["iam:*", "organizations:*", "account:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "demo-prod-boundary"
  description = "Techo de permisos para los roles de aplicacion de la plataforma"
  policy      = data.aws_iam_policy_document.boundary.json
}

###############################################################################
# 1. Rol de servicio - tareas ECS
###############################################################################

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "LeerConfiguracion"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::demo-prod-config/*"]
  }

  statement {
    sid       = "LeerSecretos"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:demo-prod/*"]
  }

  # PassRole amplio pero restringido por condicion: el patron que recomienda
  # AWS cuando no se pueden enumerar los ARN de antemano.
  statement {
    sid       = "PasarRolesSoloAEcs"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

module "role_app" {
  source = "../.."

  name        = "demo-prod-app-task"
  environment = "prod"
  description = "Rol de las tareas ECS de la aplicacion de demostracion"

  trusted_services = ["ecs-tasks.amazonaws.com"]

  # Confused deputy por el lado de los servicios: solo esta cuenta puede hacer
  # que ECS asuma el rol.
  trusted_source_account = data.aws_caller_identity.current.account_id

  inline_policies = {
    app = data.aws_iam_policy_document.app.json
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
  ]

  permissions_boundary_arn = aws_iam_policy.boundary.arn

  tags = {
    Tier = "app"
  }
}

###############################################################################
# 2. Rol cross-account
#
# El external_id es un secreto compartido con el tercero. En produccion sale de
# Secrets Manager o de una variable del pipeline, NUNCA de un tfvars en el
# repositorio.
###############################################################################

module "role_partner" {
  source = "../.."

  name        = "demo-prod-partner-readonly"
  environment = "prod"
  description = "Acceso de solo lectura para el partner de analitica"

  trusted_account_ids = [var.partner_account_id]
  external_id         = var.partner_external_id

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/ReadOnlyAccess",
  ]

  permissions_boundary_arn = aws_iam_policy.boundary.arn

  # Un tercero no necesita sesiones largas.
  max_session_duration = 3600

  tags = {
    Tier = "external"
  }
}

###############################################################################
# 3. Rol de EC2 con instance profile
###############################################################################

module "role_instance" {
  source = "../.."

  name        = "demo-prod-instance"
  environment = "prod"
  description = "Rol de las instancias EC2 de la plataforma, con acceso por SSM"

  trusted_services = ["ec2.amazonaws.com"]

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # Sin esto, el rol existe pero EC2 no puede usarlo.
  create_instance_profile = true

  permissions_boundary_arn = aws_iam_policy.boundary.arn

  tags = {
    Tier = "compute"
  }
}

###############################################################################
# Variables y outputs
###############################################################################

variable "region" {
  description = "Region de AWS donde se despliega el ejemplo."
  type        = string
  default     = "us-east-1"
}

variable "partner_account_id" {
  description = "Cuenta del tercero que puede asumir el rol de solo lectura."
  type        = string
  default     = "111122223333"
}

variable "partner_external_id" {
  description = "Identificador compartido con el tercero. En produccion sale de Secrets Manager, no de un tfvars."
  type        = string
  default     = "demo-external-id-con-entropia-suficiente"
}

output "role_arns" {
  description = "ARNs de los tres roles."
  value = {
    app      = module.role_app.arn
    partner  = module.role_partner.arn
    instance = module.role_instance.arn
  }
}

output "instance_profile_name" {
  description = "Instance profile del rol de EC2. Los otros dos devuelven null."
  value       = module.role_instance.instance_profile_name
}

output "partner_assume_role_policy" {
  description = "Politica de confianza del rol cross-account. Verificar que lleva la condicion de sts:ExternalId."
  value       = module.role_partner.assume_role_policy_json
}

output "boundary_coverage" {
  description = "Los tres roles deben llevar limite de permisos."
  value = {
    app      = module.role_app.has_permissions_boundary
    partner  = module.role_partner.has_permissions_boundary
    instance = module.role_instance.has_permissions_boundary
  }
}