###############################################################################
# Ejemplo minimo - smoke test.
#
# Rol de ejecucion de Lambda con una politica propia. La entrada mas pequena
# que produce un rol utilizable.
#
# Usa la EXENCION de permissions boundary, no porque sea lo recomendable sino
# porque un ejemplo minimo no puede exigir que exista una politica de boundary
# desplegada en la cuenta. El camino recomendado esta en examples/complete.
#
#   terraform init -backend=false && terraform validate
#
# IAM es gratuito, asi que este ejemplo tambien se puede aplicar de verdad sin
# coste - y conviene, porque AWS valida los nombres de accion en el servidor:
# un s3:GetObjectt con typo pasa el plan y lo rechaza el apply.
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

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "EscribirLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:*:log-group:/aws/lambda/demo-dev-*:*"]
  }
}

module "role" {
  source = "../.."

  name        = "demo-dev-lambda"
  environment = "dev"
  description = "Rol de ejecucion de la funcion Lambda de demostracion"

  trusted_services = ["lambda.amazonaws.com"]

  inline_policies = {
    logs = data.aws_iam_policy_document.lambda.json
  }

  boundary_exempt_reason = "Ejemplo minimo del modulo: no asume que la cuenta tenga una politica de boundary desplegada"

  tags = {
    Project = "platform-demo"
  }
}

variable "region" {
  description = "Region de AWS donde se despliega el ejemplo."
  type        = string
  default     = "us-east-1"
}

output "role_arn" {
  description = "ARN del rol, listo para pasarlo a aws_lambda_function.role."
  value       = module.role.arn
}

output "assume_role_policy_json" {
  description = "Politica de confianza generada. Util para verificar quien puede asumir el rol sin entrar a la consola."
  value       = module.role.assume_role_policy_json
}

output "has_permissions_boundary" {
  description = "False en este ejemplo: se uso la exencion documentada."
  value       = module.role.has_permissions_boundary
}