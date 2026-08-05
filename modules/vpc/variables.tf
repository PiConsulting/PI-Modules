###############################################################################
# Identity & tagging
###############################################################################

variable "name" {
  description = "Nombre base utilizado para componer el nombre de cada recurso. Convención: <cliente>-<entorno>"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "El nombre debe tener entre 3 y 32 caracteres (alfanuméricos en minúsculas y guiones) y no puede comenzar ni terminar con un guion."
  }
}

variable "environment" {
  description = "Deployment Environment"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment debe ser una de los siguientes ambientes: dev, stg, prod"
  }
}

variable "tags" {
  description = "Tags aplicados a todos los recursos creados. Se esperan tags como (Project, Owner, CostCenter)"
  type        = map(string)
  default     = {}
}

variable "vpc_tags" {
  description = "tags extras aplicados a la VPC"
  type        = map(string)
  default     = {}
}

variable "public_subnet_tags" {
  description = "tags adicionales aplicados a subnets publicas"
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "tags adicionales aplicados a subnets privadas"
  type        = map(string)
  default     = {}
}

variable "database_subnet_tags" {
  description = "tags adicionales aplicados solo a las subnets de base de datos"
  type        = map(string)
  default     = {}
}


# -------- VPC -------
variable "vpc_cidr" {
  description = "Bloque CIDR IPv4 principal de la VPC"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr debe ser un CIDR block e IPv4 valido, ej. 10.0.0.0/16."
  }

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "El prefijo de la VPC debe estar entre /16 y /24. Máscaras mayores a /24 (ej. /25) no tienen IPs suficientes para dividirse en 3 niveles multi-AZ."
  }
}

variable "secondary_cidr_blocks" {
  description = "Bloques CIDR IPv4 adicionales para la VPC. Se usan si el rango principal se agota; no crean subredes automáticamente"
  type        = list(string)
  default     = []
}

variable "availability_zones" {
  description = "Lista explicita de AZs donde el modulo desplegara recurso"
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "availability_zones debe incluir al memnos 2 AZs"
  }

  validation {
    condition     = length(var.availability_zones) == length(distinct(var.availability_zones))
    error_message = "availabiltiy_zones no debe contener valores duplicados. Cada AZs debe ser unica"
  }
}

variable "instance_tenancy" {
  description = "tipo de tenacy para las instancias EC2 lanzadas dentro de la VPC"
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "dedicated"], var.instance_tenancy)
    error_message = "instance_tenacy debe ser 'default' o 'dedicated'"
  }
}

variable "enable_dns_support" {
  description = "habilita la resolucion DNS dentro de la VPC. Necesario para Endpoints, RDS, Servicios en ECS"
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "habilita la asignacion de nombres DNS para recursos dentro de la VPC"
  type        = bool
  default     = true
}


###############################################################################
# Subnets
###############################################################################

variable "create_public_subnets" {
  description = "Indica si se deben crear subnets públicas. Desactivar este valor para VPCs privadas que se acceden mediante Transit Gateway, VPN o Direct Connect"
  type        = bool
  default     = true
}

variable "create_database_subnets" {
  description = "Indica si se deben crear subnets dedicadas para bases de datos. Recomendado para mantener la capa de datos aislada y sin acceso directo a internet"
  type        = bool
  default     = true
}


variable "subnet_newbits" {
  description = "Cantidad de bits que se agregan al CIDR de la VPC para calcular automáticamente los CIDR de las subnets. Por ejemplo, una VPC /16 con newbits=4 genera subnets /20."
  type        = number
  default     = 4

  validation {
    condition     = var.subnet_newbits >= 2 && var.subnet_newbits <= 12
    error_message = "subnet_newbits debe estar entre 2 y 12."
  }
}

variable "subnet_slots_per_tier" {
  description = "Cantidad de espacios de subred reservados por cada capa. Permite dejar lugar para agregar más AZs en el futuro sin cambiar los CIDR existentes."
  type        = number
  default     = 4

  validation {
    condition     = var.subnet_slots_per_tier >= 2 && var.subnet_slots_per_tier <= 16
    error_message = "subnet_slots_per_tier debe estar entre 2 y 16."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR explícitos para las subnets públicas, uno por cada AZ y en el mismo orden que availability_zones. Dejar vacío para calcularlos automáticamente."
  type        = list(string)
  default     = []
}

variable "private_subnet_cidrs" {
  description = "CIDR explícitos para las subnets privadas, uno por cada AZ y en el mismo orden que availability_zones. Dejar vacío para calcularlos automáticamente."
  type        = list(string)
  default     = []
}

variable "database_subnet_cidrs" {
  description = "CIDR explícitos para las subnets de base de datos, uno por cada AZ y en el mismo orden que availability_zones. Dejar vacío para calcularlos automáticamente."
  type        = list(string)
  default     = []
}

variable "map_public_ip_on_launch" {
  description = "Define si las instancias lanzadas en subnets públicas reciben una IP pública automáticamente. Se recomienda mantenerlo en false y asignar IP pública solo cuando sea necesario."
  type        = bool
  default     = false
}

variable "create_database_subnet_group" {
  description = "Define si se crea un DB Subnet Group usando las subnets de base de datos. Recomendado cuando la VPC será usada por RDS o Aurora."
  type        = bool
  default     = true
}


###############################################################################
# Egress: NAT gateways
###############################################################################

variable "nat_gateway_mode" {
  description = "Define como las subnets privadas tendran salida a internet. 'none' no crea NAT, 'single' crea un NAT compartido para toda la VPC, y 'one_per_az' crea un NAT por AZ para mayor disponibilidad"
  type        = string
  default     = "one_per_az"

  validation {
    condition     = contains(["none", "single", "one_per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode debe ser uno de estos valores: none, single u one_per_az"
  }
}

variable "database_subnets_route_to_nat" {
  description = "Indica si las subnets de base de datos tendrán una ruta por defecto a través de un NAT Gateway. Se recomienda mantener este valor en false y habilitarlo solo cuando la base de datos requiera acceso saliente a internet"
  type        = bool
  default     = false
}

###############################################################################
# VPC endpoints
###############################################################################

variable "enable_s3_endpoint" {
  description = "Define si se crea un Gtw Enpoint para S3"
  type        = bool
  default     = true
}

variable "enable_dynamodb_endpoint" {
  description = "Define si se crea un Gtw Endpoint para DynamoDB"
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Lista de servicios para crear Interface Endpoints, por ejemplo: [\"ecr.api\", \"ecr.dkr\", \"logs\", \"secretsmanager\"]. Activar solo los necesarios, ya que tienen costo por AZ."
  type        = list(string)
  default     = []
}

variable "interface_endpoints_private_dns_enabled" {
  description = "Define si se habilita DNS privado en los Interfaces Endpoints.Permite que las aplicaciones usen los endpoints privados sin cambiar el código."
  type        = bool
  default     = true
}

variable "interface_endpoints_allowed_cidrs" {
  description = "Lista de CIDR permitidos para acceder a los Interface Endpoints por HTTPS. Si se deja vacio, usa el CIDR principal de la VPC y los CIDR secundarios"
  type        = list(string)
  default     = []
}

###############################################################################
# Flow logs
###############################################################################
variable "enable_flow_logs" {
  description = "Define si se habilitan los VPC Flow Logs para registrar el trafico de red en la VPC. (Recomendacion: mantenerlo activo para facilitar el monitoreo y analisis de incidentes)"
  type        = bool
  default     = true
}

variable "flow_logs_destination_type" {
  description = "Donde se almacenaran los VPC Flow Logs. Puede ser CloudWatch o S3"
  type        = string
  default     = "cloud-watch-logs"

  validation {
    condition     = contains(["cloud-watch-logs", "s3"], var.flow_logs_destination_type)
    error_message = "flow_logs_destination_type debe ser 'cloud-watch-logs' o 's3'"
  }
}

variable "flow_logs_s3_destination_arn" {
  description = "ARN del bucket S3 donde se almacenarán los VPC Flow Logs. Este valor es obligatorio cuando el destino es S3. El bucket debe existir previamente"
  type        = string
  default     = null
}

variable "flow_logs_traffic_type" {
  description = "Especifica el tipo de tráfico que registrarán los VPC Flow Logs: ACCEPT, REJECT o ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type debe ser ACCEPT, REJECT o ALL."
  }
}

variable "flow_logs_retention_days" {
  description = "Cantidad de dias que se conserveran los VPC Flow Logs en el CloudWatchAgent logs"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days debe ser uno de los valores de retencion permitidos por CloudWatch Logs"
  }
}

variable "flow_logs_kms_key_arn" {
  description = "ARN de la clave KMS utilizada para cifrar el Log Group de CloudWatch. Si se deja en null, se utilizara la clave administrada por AWS"
  type        = string
  default     = null
}

variable "flow_logs_max_aggregation_interval" {
  description = "Intervalo de agregación de los VPC Flow Logs, en segundos. Los valores permitidos son 60 o 600."
  type        = number
  default     = 600

  validation {
    condition     = contains([60, 600], var.flow_logs_max_aggregation_interval)
    error_message = "flow_logs_max_aggregation_interval debe ser 60 o 600."
  }
}

# ------ Hardering ---------

variable "manage_default_security_group" {
  description = "Indica si el modulo administrara el SG predeterminado de la VPC, eliminando reglas de ingreso/salida configuradas por default"
  type        = bool
  default     = true
}