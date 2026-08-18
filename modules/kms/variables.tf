variable "name" {
  description = "Nombre del componente, SIN el entorno: el modulo lo antepone al componer el alias (alias/<entorno>/<nombre>) y el tag Name (<entorno>-<nombre>-kms). Diverge a proposito de la convencion <cliente>-<entorno>-<componente> de iam-role y sg: el espacio de nombres de alias de KMS es plano por region, asi que sin ese prefijo dev y prod en la misma cuenta colisionarian."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9/_-]{2,249}$", var.name))
    error_message = "El nombre debe tener entre 3 y 250 caracteres, empezar por alfanumerico y usar solo letras, numeros, barras, guiones, etc."
  }

  validation {
    condition     = !startswith(lower(var.name), "aws/")
    error_message = "El nombre no puede empezar por aws/: ese prefijo esta reservado para las claves gestionadas por aws y el alias seria rechazado en apply"
  }
}

variable "environment" {
  description = "Enorno de despliegue"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "El entorno debe ser dev, stg o prod"
  }
}

variable "description" {
  description = "Que cifra esta clave"
  type        = string

  validation {
    condition     = length(trimspace(var.description)) >= 10
    error_message = "La descripcion debe tener al menos 10 caracteres utiles. Explica que datos cifra la clave y quien la usa"
  }

  validation {
    condition     = length(var.description) <= 8192
    error_message = "La descripcion no puede superar los 8192 caracteres, que es el limite de KMS"
  }
}

variable "tags" {
  description = "Etiquetas adicionales"
  type        = map(string)
  default     = {}
}


###############################################################################
# Ciclo de vida de la clave
###############################################################################

variable "deletion_window_in_days" {
  description = "Días que la clave permanece en PendingDeletion antes de eliminarse. El valor por defecto es el máximo para permitir recuperación mediante kms:CancelKeyDeletion. CUIDADO: la clave sigue generando costos durante este período."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days debe estar entre 7 y 30"
  }

  validation {
    condition     = floor(var.deletion_window_in_days) == var.deletion_window_in_days
    error_message = "deletion_window_in_days debe ser un numero entero de dias"
  }
}

variable "rotation_period_in_days" {
  description = "Periodo de rotación automática del material criptográfico. La rotación siempre está activa. KMS conserva el material anterior para descifrar datos ya cifrados."
  type        = number
  default     = 365

  validation {
    condition     = var.rotation_period_in_days >= 90 && var.rotation_period_in_days <= 2560
    error_message = "rotation_period_in_days debe estar entre 90 y 2560 dias"
  }

  validation {
    condition     = floor(var.rotation_period_in_days) == var.rotation_period_in_days
    error_message = "rotation_period_in_days debe ser un número entero de días"
  }
}

variable "multi_region" {
  description = "Crea la clave como primaria multirregión, replicable después con el módulo kms-replica. INMUTABLE: se fija en la creación y no se convierte. Cambiarlo destruye y recrea la clave, y todo el dato cifrado con la anterior queda ilegible. Por eso se expone en v1 aunque hoy no se use: el coste de tenerlo es una variable booleana; el de no tenerlo es recifrar todo el dato del cliente."
  type        = bool
  default     = false
}

variable "is_enabled" {
  description = "Una clave deshabilitada no cifra ni descifra, pero no se borra ni se pierde. Es la palanca de contención ante un compromiso. Ponerlo en false rompe todo lo que dependa de la clave y el fallo no aparece en ningún log de aplicación: úsarlo a conciencia"
  type        = bool
  default     = true
}

variable "additional_aliases" {
  description = "Alias extra, SIN el prefijo alias/ (lo añade el módulo). Los alias son gratuitos e ilimitados en la práctica; el caso real es la migración entre claves, donde el alias antiguo apunta temporalmente a la nueva."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.additional_aliases : !startswith(lower(a), "alias/")])
    error_message = "Los valores de additional_aliases no llevan el prefijo alias/: lo compone el módulo. Con el prefijo quedaría alias/alias/<nombre>."
  }

  validation {
    condition     = alltrue([for a in var.additional_aliases : can(regex("^[a-zA-Z0-9][a-zA-Z0-9/_-]{2,249}$", a))])
    error_message = "Cada alias adicional debe tener entre 3 y 250 caracteres, empezar por alfanumérico y usar solo letras, números, barras, guiones y guiones bajos."
  }

  validation {
    condition     = alltrue([for a in var.additional_aliases : !startswith(lower(a), "aws/")])
    error_message = "Ningún alias adicional puede empezar por aws/: ese prefijo está reservado para las claves gestionadas por AWS."
  }

  validation {
    condition     = !contains(tolist(var.additional_aliases), var.name)
    error_message = "Un alias adicional no puede coincidir con name: el módulo ya crea alias/<name> y el apply fallaría con AlreadyExistsException."
  }
}

###############################################################################
# Key policy — roles modelados
#
# Aquí se modela, al revés que en iam-role, porque el dominio es acotado: tres
# categorías de principal sobre un único recurso, que es la propia clave. El
# Resource es siempre "*" y significa "esta clave", no "toda la cuenta".
#
# Las tres variables pueden quedar vacías. Una clave con solo el statement
# raíz es válida y es el caso mayoritario: delega en IAM y las políticas IAM
# de la cuenta deciden quién puede usarla. No hay validación que exija al
# menos un principal, a diferencia de iam-role, donde un rol sin origen de
# confianza no sirve para nada.
#
# Se usan listas y no mapas a propósito. La regla del repositorio (for_each
# sobre mapas) nació en sg, donde la clave del for_each salía del contenido y
# un ID desconocido en plan abortaba con "keys must be known". Aquí los ARNs
# son VALORES dentro de un bloque principals, nunca claves de un for_each: un
# ARN de un rol creado en el mismo apply es perfectamente válido.
###############################################################################

variable "key_administrators" {
  description = "ARNs de roles o usuarios IAM que administran el ciclo de vida de la clave: crear, describir, etiquetar, habilitar, programar y cancelar el borrado. NO reciben ninguna operación criptográfica. Separación de funciones: quien administra la clave no debería poder leer el dato cifrado con ella. Si un principal necesita ambas cosas, se lista también en key_users, y que esté explícito es el punto."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.key_administrators :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root$|user/.+|role/.+)", a))
    ])
    error_message = "Cada key_administrators debe ser un ARN de IAM válido: arn:aws:iam::<12-digitos>:root, :user/<nombre> o :role/<nombre>. Un ARN mal escrito no da error en AWS: produce una política válida que simplemente no concede nada."
  }
}

variable "key_users" {
  description = "ARNs de roles o usuarios IAM que usan la clave para cifrar y descifrar. Genera DOS statements: el criptográfico (Encrypt, Decrypt, ReEncrypt*, GenerateDataKey*, DescribeKey) y el de grants (CreateGrant, ListGrants, RevokeGrant) acotado con kms:GrantIsForAWSResource. Sin el segundo, un ASG con EBS cifrado no lanza instancias, RDS no crea el cluster y Lambda no configura el cifrado en reposo, todo con errores que no mencionan la palabra grant."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.key_users :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root$|user/.+|role/.+)", a))
    ])
    error_message = "Cada key_users debe ser un ARN de IAM válido: arn:aws:iam::<12-digitos>:root, :user/<nombre> o :role/<nombre>. Un ARN mal escrito no da error en AWS: produce una política válida que simplemente no concede nada."
  }
}

###############################################################################
# Key policy — principales de servicio
#
# Lista genérica, no flags curados por servicio. Un enable_cloudwatch_logs
# parece cómodo hasta que son doce flags que envejecen cada vez que AWS cambia
# un principal.
#
# La clave del mapa es el principal COMPLETO, no un alias descriptivo. Es
# único por construcción y obliga a escribir el principal regional correcto
# (logs.us-east-1.amazonaws.com), que es donde más se equivoca la gente:
# logs.amazonaws.com no falla, simplemente no concede nada.
#
# La condición aws:SourceAccount se inyecta SIEMPRE en locals.tf y no tiene
# variable. Un principal de servicio sin condición es un confused deputy: el
# servicio actúa en nombre de quien se lo pida, incluidos recursos de otras
# cuentas. Es el mismo fallo que el ExternalId ausente que iam-role ya
# convierte en error de plan, y el default ES la política.
###############################################################################

variable "service_principals" {
  description = <<-EOT
    Principales de servicio de AWS con acceso directo a la clave, indexados por el
    principal completo. El módulo inyecta siempre la condición
    aws:SourceAccount = <cuenta actual>; los campos opcionales acotan más.
 
      service_principals = {
        "logs.us-east-1.amazonaws.com" = {
          encryption_context = {
            "aws:logs:arn" = "arn:aws:logs:us-east-1:444455556666:log-group:*"
          }
        }
        "s3.amazonaws.com" = {
          via_service = ["s3.us-east-1.amazonaws.com"]
          source_arns = ["arn:aws:s3:::acme-prod-data"]
        }
      }
 
    actions            Acciones concedidas. El default cubre el uso criptográfico normal.
                       kms:CreateGrant NO está en el default: si un servicio lo necesita
                       (poco común fuera de key_users), se pide explícito en actions y el
                       módulo lo separa en su propio statement con la condición
                       kms:GrantIsForAWSResource = true, igual que hace con key_users.
    via_service        Condición kms:ViaService: la clave solo se usa a través de ese servicio.
    source_arns        Condición aws:SourceArn (ArnLike): acota el recurso concreto que la usa.
    encryption_context Condiciones kms:EncryptionContext:<clave>, una por entrada del mapa.
    EOT

  type = map(object({
    actions            = optional(list(string), ["kms:Decrypt", "kms:Encrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"])
    via_service        = optional(list(string), [])
    source_arns        = optional(list(string), [])
    encryption_context = optional(map(string), {})
  }))

  default = {}

  validation {
    condition = alltrue([
      for p, cfg in var.service_principals : can(regex("^[a-z0-9][a-z0-9.-]*\\.amazonaws\\.com$", p))
    ])
    error_message = "Cada clave de service_principals debe ser un servicio principal terminado en .amazonaws.com"
  }

  validation {
    condition = alltrue([
      for p, cfg in var.service_principals : length(cfg.actions) > 0
    ])
    error_message = "Cada entrada de service_principals debe conceder al menos una accion. Una lista vacia genera un statement que no sirve"
  }

  validation {
    condition = alltrue(flatten([
      for p, cfg in var.service_principals : [
        for a in cfg.actions : can(regex("^kms:[A-Za-z0-9*]+$", a))
      ]
    ]))
    error_message = "Las acciones de service_principals deben pertenecer al espacio kms:. Una key policy solo gobierna acciones de KMS: cualquier otra cosa es válida sintácticamente y no concede nada."
  }

  validation {
    condition = alltrue(flatten([
      for p, cfg in var.service_principals : [
        for s in cfg.via_service : can(regex("^[a-z0-9][a-z0-9.-]*\\.amazonaws\\.com$", s))
      ]
    ]))
    error_message = "Cada via_service debe ser un endpoint de servicio terminado en .amazonaws.com, normalmente regional: s3.us-east-1.amazonaws.com."
  }

  validation {
    condition = alltrue(flatten([
      for p, cfg in var.service_principals : [
        for k, v in cfg.encryption_context : length(trimspace(k)) > 0 && length(trimspace(v)) > 0
      ]
    ]))
    error_message = "Las claves y los valores de encryption_context no pueden estar vacíos: una condición con valor vacío nunca se cumple y bloquea el acceso en silencio."
  }
}

###############################################################################
# Key policy — escape
#
# ADITIVO, nunca sustitutivo. Se fusiona con source_policy_documents y el
# statement raíz de la cuenta sobrevive siempre. Un escape que reemplazase la
# política completa sería el equivalente a dejar que el consumidor sobreescriba
# el permissions boundary.
#
# Lo que NO se puede comprobar aquí y va en precondition (main.tf), porque
# necesita jsondecode y normalización:
#   1. Colisión con los Sids reservados del módulo. La fusión de
#      aws_iam_policy_document resuelve colisiones por Sid, así que reutilizar
#      EnableIAMUserPermissions pisa el statement raíz SIN NINGÚN ERROR.
#   2. Effect: Deny combinado con NotPrincipal. Es el vector de lockout que
#      sobrevive al statement raíz: deniega a todo el mundo salvo a los
#      listados, incluida la cuenta, incluido kms:PutKeyPolicy.
#   3. Principal comodín sin Condition.
#   4. kms:* o kms:PutKeyPolicy concedido a un principal externo.
###############################################################################

variable "extra_policy_json" {
  description = "Statements adicionales de la key policy: el .json de un aws_iam_policy_document construido en el root, no JSON escrito a mano. Se AÑADEN a los statements del módulo, no los reemplazan. El caso real es el acceso cross-account condicionado. El módulo inspecciona este documento y lo rechaza en plan si compromete el acceso a la propia clave."
  type        = string
  default     = null

  validation {
    condition     = var.extra_policy_json == null ? true : can(jsondecode(var.extra_policy_json))
    error_message = "extra_policy_json debe ser JSON válido. Usa data.aws_iam_policy_document.<x>.json en lugar de escribirlo a mano."
  }

  validation {
    condition     = var.extra_policy_json == null ? true : can(jsondecode(var.extra_policy_json).Statement)
    error_message = "extra_policy_json debe tener una clave Statement. Parece un documento de política incompleto."
  }
}
  