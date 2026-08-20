###############################################################################
#
# Ejercita el contrato entero. Es el ejemplo que de verdad valida el modulo:
# minimal solo demuestra que el camino feliz compila.
#
# Lo que fuerza, en concreto:
#
#   - kms_key_arn: sse_algorithm tiene que salir aws:kms, no AES256.
#   - Server access logging con un SEGUNDO bucket del propio modulo como
#     destino -es el caso real documentado en la variable- con la bucket
#     policy que ese destino necesita para aceptar escrituras de
#     logging.s3.amazonaws.com. Con Object Ownership BucketOwnerEnforced (ACLs
#     deshabilitadas de forma no negociable) el metodo legado de log delivery
#     por ACL no existe: esta policy es la unica forma.
#   - custom_bucket_policy: el escape aditivo, con las 4 preconditions
#     anti-lockout del modulo evaluandolo de verdad.
#   - lifecycle_transitions con dos storage class distintas.
#   - Overrides de noncurrent_version_expiration_days y
#     abort_incomplete_multipart_upload_days.
#   - force_destroy = true, PORQUE ESTO ES UN LABORATORIO: en prod se deja el
#     default (false), que es la proteccion de datos real.
#
# AVISO DE COSTE: crea una clave KMS real, ~1 USD/mes mientras exista.
#
###############################################################################

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
      Example = "s3/complete"
    }
  }
}

variable "region" {
  description = "Region donde se crea todo."
  type        = string
  default     = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

###############################################################################
# Nombres y ARNs, resueltos ANTES de crear nada
#
# arn:aws:s3:::<nombre> es predecible desde el nombre. Componerlo aqui evita
# que el bucket principal y el bucket de logs se referencien via outputs del
# modulo del otro -eso si generaria un ciclo real (cada uno esperaria el
# apply del otro).
###############################################################################

locals {
  main_bucket = "pi-modules-s3-complete-${random_id.suffix.hex}"
  logs_bucket = "pi-modules-s3-complete-logs-${random_id.suffix.hex}"

  main_bucket_arn = "arn:aws:s3:::${local.main_bucket}"
  logs_bucket_arn = "arn:aws:s3:::${local.logs_bucket}"
}

###############################################################################
# La clave KMS
#
# Creada aqui, NO con el modulo kms del catalogo: un example no debe
# acoplarse al tag de otro modulo (misma razon que en kms/examples/complete
# con iam-role). deletion_window_in_days en 7 -el minimo- por ser
# laboratorio; en un caso real se deja el default mas alto.
###############################################################################

resource "aws_kms_key" "this" {
  description             = "Cifrado del bucket principal de este example"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

###############################################################################
# La policy que necesita el bucket de logs
#
# El statement estandar de S3 server access logging por bucket policy.
# SourceAccount + SourceArn acotan el statement a ESTE bucket principal: sin
# esa condicion, cualquier bucket de la cuenta podria escribir logs aqui.
###############################################################################

data "aws_iam_policy_document" "logs_delivery" {
  statement {
    sid    = "S3ServerAccessLogsPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${local.logs_bucket_arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.main_bucket_arn]
    }
  }
}

###############################################################################
# El bucket de logs
###############################################################################

module "s3_logs" {
  source = "../../"

  bucket_name = local.logs_bucket
  environment = "dev"

  custom_bucket_policy = data.aws_iam_policy_document.logs_delivery.json
}

###############################################################################
# El bucket principal
#
# depends_on explicito: logging_target_bucket es un string (local), no una
# referencia a modulo -no genera dependencia implicita. Pero PutBucketLogging
# en la API de S3 exige que el bucket destino YA exista y tenga su policy
# aplicada. Sin este depends_on, Terraform puede intentar configurar el
# logging del bucket principal antes de que el bucket de logs este listo, y
# el apply falla aunque el plan haya compilado.
###############################################################################

module "s3_main" {
  source = "../../"

  depends_on = [module.s3_logs]

  bucket_name = local.main_bucket
  environment = "dev"

  kms_key_arn = aws_kms_key.this.arn

  logging_target_bucket = local.logs_bucket
  logging_target_prefix = "logs/${local.main_bucket}/"

  noncurrent_version_expiration_days     = 45
  abort_incomplete_multipart_upload_days = 3

  lifecycle_transitions = [
    {
      days          = 90
      storage_class = "STANDARD_IA"
    },
    {
      days          = 180
      storage_class = "GLACIER"
    },
  ]

  # Solo para poder hacer destroy sin vaciar el bucket a mano. En prod se deja
  # el default (false): es la proteccion de datos real.
  force_destroy = true
}

###############################################################################
# Outputs
###############################################################################

output "posture" {
  description = "Postura del modulo, evaluable en plan."
  value = {
    main = {
      sse_algorithm      = module.s3_main.sse_algorithm
      versioning_enabled = module.s3_main.versioning_enabled
      has_custom_policy  = module.s3_main.has_custom_policy
    }
    logs = {
      sse_algorithm      = module.s3_logs.sse_algorithm
      versioning_enabled = module.s3_logs.versioning_enabled
      has_custom_policy  = module.s3_logs.has_custom_policy
    }
  }
}