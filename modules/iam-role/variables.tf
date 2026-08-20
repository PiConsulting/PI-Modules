variable "name" {
  description = "Nombre del rol. Convencion: <cliente>-<entorno>-<rol>"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "name debe tener entre 3 y 64 caracteres, solo minusculasm numeros y guiones, sin empezar ni terminar con guion"
  }
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "debe ser un environment: dev, stg o prod"
  }
}

variable "description" {
  description = "descripcion del rol"
  type        = string

  validation {
    condition     = length(trimspace(var.description)) >= 10
    error_message = "description debe tener al menos 10 caracteres utiles, explica que hace el rol, no que es un rol"
  }
}

variable "path" {
  description = "ruta IAM del rol, util para organizarse en terminos de equipos o servicios"
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^/([a-zA-Z0-9+=,.@_-]+/)*$", var.path))
    error_message = "path debe empezar y terminar con / , por ejemplo / o /plataforma/."
  }
}

variable "max_session_duration" {
  description = "duracion maxima de una sesion asumida, en segundos. El default es 1 hora: AWS permite hasta 12, pero un default no debe ser nunca al maximo"
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration debe estar entre 3600 (1 hora) y 43200 (12 horas)"
  }
}

###############################################################################
# Politica de confianza
#
# Quien puede asumir el rol. Es la mitad de la seguridad de IAM y la que mas se
# descuida: de nada sirve una politica de permisos impecable si cualquiera
# puede asumir el rol que la lleva.
###############################################################################

variable "trusted_services" {
  description = "principales servicios que pueden asumir el rol, ej: [\"ecs-task.amazonaws\\.com$]"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for s in var.trusted_services : can(regex("\\.amazonaws\\.com$", s))
    ])
    error_message = "Cada entrada de trusted_services debe ser un principal de servicio terminado en .amazonaws.com."
  }

  validation {
    condition     = length(var.trusted_services) > 0 || length(var.trusted_account_ids) > 0
    error_message = "El rol necesita al menos un trusted_services o un trusted_account_ids. Sin origen de confianza, nadie puede asumirlo."
  }
}

variable "trusted_account_ids" {
  description = "Cuentas de AWS que pueden asumir el rol. Exige external_id: sin condicion, cualquiera de esa cuenta con permiso de sts:AssumeRole puede asumirlo."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.trusted_account_ids : can(regex("^[0-9]{12}$", a))
    ])
    error_message = "Cada trusted_account_ids debe ser un ID de cuenta de AWS de 12 digitos."
  }
}

variable "external_id" {
  description = "Identificador compartido con el tercero, exigido en la politica de confianza cross-account. NO lo pongas en un tfvars: sale de Secrets Manager o de una variable del pipeline."
  type        = string
  default     = null

  validation {
    condition = (
      length(var.trusted_account_ids) == 0 ? true : (
        var.external_id == null ? false : length(var.external_id) >= 16
      )
    )
    error_message = "Con trusted_account_ids hay que pasar un external_id de al menos 16 caracteres. Sin el, el rol es vulnerable al confused deputy: cualquiera de la cuenta de confianza puede asumirlo, no solo el sistema con el que acordaste el acceso."
  }
}

variable "trusted_source_account" {
  description = "Cuenta que se exige en la condicion aws:SourceAccount para los principales de servicio. Evita que un servicio de AWS actuando en nombre de otra cuenta pueda asumir el rol."
  type        = string
  default     = null

  validation {
    condition     = var.trusted_source_account == null ? true : can(regex("^[0-9]{12}$", var.trusted_source_account))
    error_message = "trusted_source_account debe ser un ID de cuenta de AWS de 12 digitos."
  }
}

###############################################################################
# Permisos
###############################################################################

variable "managed_policy_arns" {
  description = "ARNs de politicas gestionadas a adjuntar, de AWS o del cliente."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.managed_policy_arns :
      can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", a))
    ])
    error_message = "Cada managed_policy_arns debe ser un ARN de politica IAM valido."
  }
}

variable "inline_policies" {
  description = "Politicas propias del rol, indexadas por un nombre descriptivo. El valor es el .json de un aws_iam_policy_document construido en el root: no escribas JSON a mano. Se crean como inline para que se borren con el rol y no queden politicas huerfanas en la cuenta."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.inline_policies : can(jsondecode(v))
    ])
    error_message = "Cada valor de inline_policies debe ser JSON valido. Usa data.aws_iam_policy_document.<x>.json en lugar de escribirlo a mano."
  }

  validation {
    condition = alltrue([
      for k, v in var.inline_policies : can(jsondecode(v).Statement)
    ])
    error_message = "Cada politica de inline_policies debe tener una clave Statement. Parece un documento de politica incompleto."
  }
}

###############################################################################
# Limite de permisos
#
# El permissions boundary es el techo de lo que el rol puede hacer, por encima
# de sus propias politicas. Sin el, un rol con permiso de crear roles puede
# crear uno mas privilegiado que el mismo: la escalada clasica.
#
# Es obligatorio, pero con una salida documentada: exigirlo sin escape impide
# usar el modulo a cualquier cliente que aun no tenga una politica de boundary
# desplegada, que son todos el primer dia.
###############################################################################

variable "permissions_boundary_arn" {
  description = "ARN de la politica que actua como limite de permisos. El modulo no la crea: es responsabilidad del equipo de seguridad o del modulo iam-policy."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn debe ser un ARN de politica IAM valido."
  }
}

variable "boundary_exempt_reason" {
  description = "Justificacion escrita de por que este rol no lleva limite de permisos. Solo se usa si permissions_boundary_arn es null. Queda en el codigo y es revisable en un pull request, que es justo el punto."
  type        = string
  default     = null

  validation {
    condition = (
      var.permissions_boundary_arn != null ? true : (
        var.boundary_exempt_reason == null ? false : length(trimspace(var.boundary_exempt_reason)) >= 20
      )
    )
    error_message = "Todo rol necesita permissions_boundary_arn, o bien un boundary_exempt_reason de al menos 20 caracteres que un auditor aceptaria. La excepcion se permite; que no quede escrita, no."
  }
}

###############################################################################
# Extras
###############################################################################

variable "create_instance_profile" {
  description = "crear un instance profile asociado al rol. Solo lo necesitan EC2 y los asg; para lamba, EC2 o RDS sirve"
  type        = bool
  default     = false
}

variable "tags" {
  description = "tags aplicados al rol. Se esperan las asignaciones: Project, Owner, CostCenter"
  type        = map(string)
  default     = {}
}