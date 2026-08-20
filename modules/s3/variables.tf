variable "bucket_name" {
  description = "Nombre completo y global del bucket S3. Obligatorio,sin default: el modulo no resuelve la unicidad global de nombres."
  type        = string

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63
    error_message = "bucket_name debe tener entre 3 y 63 caracteres"
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name debe usar solo minusculas, numeros, puntos y guiones, y empezar y terminar con una letra o numero."
  }

  validation {
    condition     = !can(regex("\\.\\.", var.bucket_name))
    error_message = "bucket_name no puede tener dos puntos seguidos (..): S3 lo rechaza en apply, no antes."
  }

  validation {
    condition     = !can(regex("^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", var.bucket_name))
    error_message = "bucket_name no puede tener formato de direccion IP (ej. 192.168.5.4): S3 lo prohibe explicitamente."
  }
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "El entorno debe ser: dev, stg o prod"
  }
}

variable "tags" {
  description = "tags adicionales"
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "ARN de la CMK de KMS para SSE-KMS (normalmente el output key_arn del modulo kms). Si se omite, el bucket cae automaticamente a SSE-S3 (AES256): nunca queda sin cifrar"
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null ? true : can(regex("^arn:aws[a-z0-9-]*:kms:[a-z0-9-]+:[0-9]{12}:(key/[a-zA-Z0-9-]+|alias/.+)$", var.kms_key_arn))
    error_message = "kms_key_arn debe ser un ARN de KMS valido: arn:aws:kms:<region>:<12-digitos>:key/<id> o :alias/<nombre>. Un ARN mal escrito no falla en plan si no se valida: S3 lo rechazaria recien en apply."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Dias que una version no-actual de un objeto se conserva antes de expirar (eliminacion definitiva). Con versioning siempre activo, sin este limite el bucket crece de forma invisible: cada sobreescritura o borrado deja una version anterior facturando para siempre."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1 && var.noncurrent_version_expiration_days <= 3650
    error_message = "noncurrent_version_expiration_days debe estar entre 1 y 3650 dias (10 anios)."
  }

  validation {
    condition     = floor(var.noncurrent_version_expiration_days) == var.noncurrent_version_expiration_days
    error_message = "noncurrent_version_expiration_days debe ser un numero entero de dias."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Dias que un multipart upload incompleto (interrumpido por un cliente, un timeout, un crash) permanece antes de abortarse y liberar el storage que ya ocupaba. Sin este limite, uploads fallidos que nadie completo ni cancelo se facturan indefinidamente sin aparecer en ningun listado normal de objetos."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_upload_days >= 1 && var.abort_incomplete_multipart_upload_days <= 3650
    error_message = "abort_incomplete_multipart_upload_days debe estar entre 1 y 3650 dias."
  }

  validation {
    condition     = floor(var.abort_incomplete_multipart_upload_days) == var.abort_incomplete_multipart_upload_days
    error_message = "abort_incomplete_multipart_upload_days debe ser un numero entero de dias."
  }
}

variable "force_destroy" {
  description = "permite terraform destroy con objetos dentro del bucket (los borra primero). Default en false: proteccion de datos."
  type        = bool
  default     = false
}

variable "logging_target_bucket" {
  description = "Nombre del bucket destino de server access logging. Si se omite, el bucket no genera logs de acceso via este mecanismo (S3 registra eventos via CloudTrail data events)"
  type        = string
  default     = null

  validation {
    condition     = var.logging_target_bucket == null ? true : (length(var.logging_target_bucket) >= 3 && length(var.logging_target_bucket) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.logging_target_bucket)))
    error_message = "logging_target_bucket debe ser un nombre de bucket S3 valido (3-63 caracteres, minusculas, numeros, puntos y guiones)."
  }

  validation {
    condition     = var.logging_target_bucket == null ? true : var.logging_target_bucket != var.bucket_name
    error_message = "logging_target_bucket no puede ser el mismo bucket (bucket_name): un bucket registrandose a si mismo genera un crecimiento de logs sin limite. Usa una segunda invocacion del modulo para el bucket destino."
  }
}

variable "logging_target_prefix" {
  description = "Prefijo de key para los logs dentro de logging_target_bucket (ej. 'logs/mi-bucket/'). Solo tiene efecto si logging_target_bucket esta definido."
  type        = string
  default     = null

  validation {
    condition     = var.logging_target_prefix == null ? true : var.logging_target_bucket != null
    error_message = "logging_target_prefix requiere logging_target_bucket: no tiene sentido un prefijo sin bucket destino."
  }
}

variable "custom_bucket_policy" {
  description = "Statements adicionales de la bucket policy: el .json de un aws_iam_policy_document construido en el root, no JSON escrito a mano. Se AÑADEN a los statements del modulo (deny de transporte inseguro y cualquier otro statement base), nunca los reemplazan. Casos reales: la bucket policy que necesita el destino de server access logging (logging.s3.amazonaws.com), o la policy de Origin Access Control para CloudFront. El modulo inspecciona este documento y lo rechaza en plan si compromete la seguridad base del bucket."
  type        = string
  default     = null

  validation {
    condition     = var.custom_bucket_policy == null ? true : can(jsondecode(var.custom_bucket_policy))
    error_message = "custom_bucket_policy debe ser JSON valido. Usa data.aws_iam_policy_document.<x>.json en lugar de escribirlo a mano."
  }

  validation {
    condition     = var.custom_bucket_policy == null ? true : can(jsondecode(var.custom_bucket_policy).Statement)
    error_message = "custom_bucket_policy debe tener una clave Statement. Parece un documento de politica incompleto."
  }
}

variable "lifecycle_transitions" {
  description = "Transiciones opcionales de storage class por antiguedad del objeto (ej. a STANDARD_IA a los 90 dias, a GLACIER a los 180). Vacia por defecto: el modulo no impone abaratamiento automatico, depende del patron de acceso de cada caso de uso."
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = []

  validation {
    condition = alltrue([
      for t in var.lifecycle_transitions :
      contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"], t.storage_class)
    ])
    error_message = "storage_class debe ser una de: STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER_IR, GLACIER, DEEP_ARCHIVE."
  }

  validation {
    condition = alltrue([
      for t in var.lifecycle_transitions :
      t.days >= 1 && floor(t.days) == t.days
    ])
    error_message = "days debe ser un numero entero positivo de dias."
  }

  validation {
    condition = alltrue([
      for t in var.lifecycle_transitions :
      contains(["STANDARD_IA", "ONEZONE_IA"], t.storage_class) ? t.days >= 30 : true
    ])
    error_message = "STANDARD_IA y ONEZONE_IA exigen al menos 30 dias: es un minimo duro de S3, y sin esta validacion el error aparece recien en apply (InvalidArgument: Days must be at least 30)."
  }

  validation {
    condition     = length(distinct([for t in var.lifecycle_transitions : t.storage_class])) == length(var.lifecycle_transitions)
    error_message = "No puede haber dos transiciones a la misma storage_class: S3 rechaza reglas de lifecycle con storage classes duplicadas dentro de la misma regla."
  }
}