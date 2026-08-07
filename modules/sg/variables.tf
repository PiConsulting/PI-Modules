variable "name" {
  description = "Nombre base del sg. Convencion: <cliente>-<entorno>-<rol>, por ejemplo acme-prod-alb, se usa como name_prefix, asi AWS le añade un subfijo aleatorio"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name debe tener entre 3 y 32 caracteres, solo minusculas, numeros y guiones, no puede empezar ni terminar con guion"
  }
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "debe ser un environment: dev, stg, prod"
  }
}

variable "vpc_id" {
  description = "ID de la VPC donde vive el SG"
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id debe tener el formato vpc-xxxxxxx"
  }
}

variable "description" {
  description = "Descripcion del sg. Sin default a proposito: AWS pone 'Managed by Terraform', que no dice absolutamente nada sobre para que sirve el grupo."
  type        = string

  validation {
    condition     = length(trimspace(var.description)) >= 10
    error_message = "description debe tener al menos 10 caracteres utiles. Explica que protege este grupo, no que es un security group."
  }
}


# Reglas de entrada
#
# Es un map, no una lista, y esa es la decision de diseño central del modulo.
#
# Con for_each sobre una lista, la clave se deriva del contenido. Si una regla
# referencia un security group creado en el mismo apply -el caso del encadenado
# alb -> app -> database- ese ID es desconocido en tiempo de plan y Terraform
# aborta con "the given keys must be known".
#
# Con un map, la clave la elige el consumidor y siempre se conoce en plan,
# aunque el valor no. La cadena completa se levanta en un solo apply.
#
# Efecto secundario util: obliga a nombrar cada regla, y el plan muestra
# ["postgres-desde-app"] en lugar de [3].

variable "ingress_rules" {
  description = "Reglas de entrada, indexadas por un nombre descriptivo elegido por el consumidor. Cada entrada genera un recurso de regla por cada CIDR y por cada sg"
  type = map(object({
    description               = string
    from_port                 = number
    to_port                   = number
    protocol                  = optional(string, "tcp")
    cidr_blocks               = optional(list(string), [])
    source_security_group_ids = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules : length(trimspace(r.description)) >= 5
    ])
    error_message = "Todo ingress necesita una descripcion de al menos 5 caracteres"
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      length(r.cidr_blocks) > 0 || length(r.source_security_group_ids) > 0
    ])
    error_message = "Todo ingress necesita al menos un cidr_blocks o un source_security_group_ids"
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules : r.from_port <= r.to_port
    ])
    error_message = "from_port debe ser menor o igual que to_port en toda regla de entrada"
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      contains(["tcp", "udp", "icmp", "icmpv6"], r.protocol)
    ])
    error_message = "protocol debe ser tcp, udp, icmp o icmpv6. El protocolo -1 (todos) no se admite en reglas de usuario en la v1: usa allow_all_egress para el caso de salida abierta"
  }

  # La regla que justifica media existencia del modulo.
  #
  # Comprueba RANGOS, no puertos exactos: una regla 0-65535 desde 0.0.0.0/0
  # tambien se rechaza, que es justo lo que la gente escribe "temporalmente" y
  # se queda seis meses.
  #
  # La lista de puertos va inline porque un bloque validation no puede
  # referenciar un local.
  validation {
    condition = alltrue([
      for k, r in var.ingress_rules : !(
        anytrue([for c in r.cidr_blocks : c == "0.0.0.0/0" || c == "::/0"]) &&
        anytrue([
          for p in [22, 3389, 5432, 3306, 1433, 6379, 27017, 9200, 11211] :
          r.from_port <= p && r.to_port >= p
        ])
      )
    ])
    error_message = "Prohibido exponer puertos administrativos o de base de datos (22, 3389, 5432, 3306, 1433, 6379, 27017, 9200, 11211) a 0.0.0.0/0 o ::/0. Usa source_security_group_ids o un CIDR acotado."
  }
}


######### Reglas de salida #############

variable "allow_all_egress" {
  description = "Permitir toda la salida a 0.0.0.0/0. Es lo que AWS pone por defecto. Poner en false solo cuando el cliente exija egress restringido, recordar abrir DNS, NTP, los VPC endpoints y las actualizaciones de paquetes."
  type        = bool
  default     = true
}

variable "egress_rules" {
  description = "Reglas de salida explicitas. Solo se aplican cuando allow_all_egress es false. Misma estructura que ingress_rules, pero source_security_group_ids se interpreta como destino."
  type = map(object({
    description               = string
    from_port                 = number
    to_port                   = number
    protocol                  = optional(string, "tcp")
    cidr_blocks               = optional(list(string), [])
    source_security_group_ids = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, r in var.egress_rules : length(trimspace(r.description)) >= 5
    ])
    error_message = "Toda regla de salida necesita una description de al menos 5 caracteres."
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      length(r.cidr_blocks) > 0 || length(r.source_security_group_ids) > 0
    ])
    error_message = "Toda regla de salida necesita al menos un cidr_blocks o un source_security_group_ids."
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules : r.from_port <= r.to_port
    ])
    error_message = "from_port debe ser menor o igual que to_port en toda regla de salida."
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      contains(["tcp", "udp", "icmp", "icmpv6"], r.protocol)
    ])
    error_message = "protocol debe ser tcp, udp, icmp o icmpv6."
  }

  # No hay validacion de puertos administrativos en egress: salir hacia el
  # 5432 de una base de datos es exactamente lo que hace una aplicacion.
}

variable "tags" {
  description = "Tags aplicados al sg y cada regla. Se esperan las asignaciones: Project, Owner, CostCenter"
  type        = map(string)
  default     = {}

}