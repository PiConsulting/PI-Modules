###############################################################################
# Ejemplo completo - la cadena alb -> app -> database.
#
# Es el primer sitio del repositorio donde dos modulos propios se componen, y
# esa es su razon de ser: demuestra que la plataforma encaja, no solo que cada
# pieza valida por separado.
#
# Prueba la decision de diseno central del modulo: las reglas son un MAPA, asi
# que las claves de for_each se conocen en plan aunque los IDs de los security
# groups de origen no existan todavia. La cadena entera se levanta en un solo
# apply, sin depends_on ni dos pasadas.
#
# Coste: nat_gateway_mode = "none" y sin flow logs, para que el ejemplo se
# pueda aplicar sin factura. La configuracion de produccion de la VPC esta en
# modules/vpc/examples/complete.
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

###############################################################################
# Red
###############################################################################

module "vpc" {
  source = "../../../vpc"

  name        = "demo-sg"
  environment = "dev"

  vpc_cidr           = "10.30.0.0/16"
  availability_zones = ["${var.region}a", "${var.region}b"]

  # Sin salida a internet y sin flow logs: el ejemplo debe poder aplicarse
  # sin coste. Los gateway endpoints son gratis, asi que se dejan.
  nat_gateway_mode = "none"
  enable_flow_logs = false

  tags = {
    Project = "platform-demo"
  }
}

###############################################################################
# Capa de entrada
###############################################################################

module "sg_alb" {
  source = "../.."

  name        = "demo-sg-alb"
  environment = "dev"
  vpc_id      = module.vpc.vpc_id
  description = "Balanceador de aplicacion expuesto a internet"

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
    Tier    = "edge"
  }
}

###############################################################################
# Capa de aplicacion
#
# Solo acepta trafico del security group del ALB. Nunca por CIDR: si manana la
# subred del ALB cambia, la regla sigue siendo correcta.
###############################################################################

module "sg_app" {
  source = "../.."

  name        = "demo-sg-app"
  environment = "dev"
  vpc_id      = module.vpc.vpc_id
  description = "Tareas de aplicacion en subredes privadas"

  ingress_rules = {
    "app-desde-alb" = {
      description               = "Trafico de aplicacion desde el ALB"
      from_port                 = 8080
      to_port                   = 8080
      source_security_group_ids = [module.sg_alb.id]
    }
    "metricas-desde-vpc" = {
      description = "Scraping de metricas desde dentro de la VPC"
      from_port   = 9090
      to_port     = 9090
      cidr_blocks = module.vpc.vpc_all_cidr_blocks
    }
  }

  tags = {
    Project = "platform-demo"
    Tier    = "app"
  }
}

###############################################################################
# Capa de datos
#
# Egress cerrado: una base de datos no inicia conexiones salientes. Es el unico
# sitio del ejemplo donde allow_all_egress se pone en false, y muestra que la
# restriccion se activa por caso concreto, no por defecto.
###############################################################################

module "sg_database" {
  source = "../.."

  name        = "demo-sg-database"
  environment = "dev"
  vpc_id      = module.vpc.vpc_id
  description = "Cluster de base de datos en subredes aisladas"

  ingress_rules = {
    "postgres-desde-app" = {
      description               = "Postgres desde las tareas de aplicacion"
      from_port                 = 5432
      to_port                   = 5432
      source_security_group_ids = [module.sg_app.id]
    }
  }

  allow_all_egress = false

  egress_rules = {
    "respuesta-a-app" = {
      description               = "Respuestas hacia las tareas de aplicacion"
      from_port                 = 1024
      to_port                   = 65535
      source_security_group_ids = [module.sg_app.id]
    }
  }

  tags = {
    Project = "platform-demo"
    Tier    = "data"
  }
}

variable "region" {
  description = "Region de AWS donde se despliega el ejemplo."
  type        = string
  default     = "us-east-1"
}

output "vpc_id" {
  description = "ID de la VPC creada."
  value       = module.vpc.vpc_id
}

output "security_group_ids" {
  description = "IDs de los tres security groups de la cadena."
  value = {
    alb      = module.sg_alb.id
    app      = module.sg_app.id
    database = module.sg_database.id
  }
}

output "database_egress_is_restricted" {
  description = "Confirma que la capa de datos no tiene salida abierta."
  value       = !module.sg_database.allow_all_egress
}