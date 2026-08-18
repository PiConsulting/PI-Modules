# ============================================================================
# DATA SOURCES - Información de contexto de AWS
# ============================================================================

# Obtiene la partición de AWS actual (aws, aws-cn, aws-us-gov)
# Se usa para construir ARNs correctamente según la región
data "aws_partition" "current" {}

# Obtiene el Account ID y ARN de la cuenta actual
# Usado en las políticas para referirse a "esta cuenta"
data "aws_caller_identity" "current" {}

# ============================================================================
# IAM POLICY DOCUMENT - Construcción de la Key Policy
# ============================================================================
# Esta policy define quién puede usar y administrar la clave KMS
# IMPORTANTE: Las claves KMS requieren una key policy (no basta con IAM policies)
data "aws_iam_policy_document" "key" {
  # Permite inyectar statements adicionales desde el caller
  # Si necesitas permisos custom (ej: permitir acceso desde otra cuenta),
  # pasa un JSON válido en var.extra_policy_json
  # CUIDADO: Los Sids no deben colisionar con los del módulo (ver lifecycle preconditions)
  source_policy_documents = var.extra_policy_json == null ? [] : [var.extra_policy_json]

  # Itera sobre los statements predefinidos del módulo (generados en locals.tf)
  # Incluye: statement raíz (delegación IAM), service statements (S3, CloudWatch, etc)
  dynamic "statement" {
    for_each = local.policy_statements

    content {
      sid       = statement.value.sid       # Identificador único del statement
      effect    = statement.value.effect    # Allow o Deny
      actions   = statement.value.actions   # Lista de acciones KMS (kms:Encrypt, kms:Decrypt, etc)
      resources = statement.value.resources # Siempre ["*"] para key policies

      # Principals: quién puede ejecutar estas acciones
      # Puede ser: AWS accounts, IAM roles/users, servicios de AWS
      dynamic "principals" {
        for_each = statement.value.principals

        content {
          type        = principals.value.type        # "AWS", "Service", "Federated"
          identifiers = principals.value.identifiers # ARNs o nombres de servicio
        }
      }

      # Conditions: restricciones adicionales (opcional)
      # Ej: solo desde cierta VPC, solo vía servicio específico, etc
      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test     # StringEquals, ArnLike, etc
          variable = condition.value.variable # aws:SourceAccount, kms:ViaService, etc
          values   = condition.value.values   # Valores a comparar
        }
      }
    }
  }
}

# ============================================================================
# KMS KEY - Recurso principal de cifrado
# ============================================================================
# Crea una clave KMS Customer Managed Key (CMK)
# AWS cobra ~$1/mes por clave + uso de API
resource "aws_kms_key" "this" {
  # Descripción legible para humanos (aparece en consola AWS)
  description = var.description

  # Policy JSON que define permisos (generada arriba)
  policy = data.aws_iam_policy_document.key.json

  # Días de espera antes de eliminar la clave (7-30 días)
  # RECOMENDADO: 30 para producción (recuperación ante errores)
  # Si necesitas borrado más rápido en dev/test, usa 7
  deletion_window_in_days = var.deletion_window_in_days

  # Si la clave está habilitada para operaciones criptográficas
  # Puedes deshabilitar temporalmente sin eliminar
  is_enabled = var.is_enabled

  # Multi-region: crea réplicas automáticas en otras regiones
  # Útil para DR/HA cross-region, pero aumenta costos
  # CAMBIAR: true solo si necesitas failover regional
  multi_region = var.multi_region

  # SEGURIDAD: Rotación automática de material criptográfico
  # OBLIGATORIO: siempre true (best practice de AWS)
  # No afecta a datos ya cifrados (KMS mantiene versiones anteriores)
  enable_key_rotation = true

  # Frecuencia de rotación en días (90-2560)
  # DEFAULT: 365 días (anual) - balance entre seguridad y complejidad operativa
  # CAMBIAR: 90 para ambientes con requisitos de seguridad más estrictos
  rotation_period_in_days = var.rotation_period_in_days

  # SEGURIDAD: Previene lockout accidental al cambiar la policy
  # OBLIGATORIO: false (protección contra errores)
  # Solo cambiar a true si sabes exactamente lo que haces
  bypass_policy_lockout_safety_check = false

  # Tags estándar del módulo (incluye Environment, Project, etc)
  tags = local.tags

  # ============================================================================
  # LIFECYCLE PRECONDITIONS - Validaciones de seguridad pre-apply
  # ============================================================================
  # Estas validaciones evitan configuraciones peligrosas que podrían causar lockout
  # o exponer la clave. Se ejecutan ANTES de terraform apply.
  lifecycle {
    # PRECONDITION 1: Previene colisión de Sids con el módulo
    # Si usas extra_policy_json, tus Sids no pueden duplicar los del módulo
    # RAZÓN: aws_iam_policy_document fusiona por Sid, un duplicado SILENCIOSAMENTE
    #        reemplaza el statement del módulo, pudiendo causar lockout
    precondition {
      condition     = length(local.custom_sid_collisions) == 0
      error_message = <<-EOT
      extra_policy_json usa Sids reservados por el modulo: ${join(", ", local.custom_sid_collisions)}
      Reservados: ${join(", ", local.reserved_sids)}, y cualquiera que empiece por "${local.service_sid_prefix}"

      IMPACTO: aws_iam_policy_document resuelve la fusion POR Sid. Un Sid duplicado
        sustituye al statement del modulo SIN emitir ningun error. Si pisas
        "${local.sid_root}" pierdes la delegacion en IAM y quedas fuera de tu propia
        clave: kms:PutKeyPolicy tambien se rige por la key policy.
 
        SOLUCION: renombra el Sid de tu statement.
      EOT  
    }

    # PRECONDITION 2: Previene lockout con Deny + NotPrincipal
    # Esta es la ÚNICA forma de lockout que el statement raíz NO puede prevenir
    # RAZÓN: Deny siempre gana sobre Allow, incluso sobre el statement raíz
    precondition {
      condition     = length(local.custom_deny_notprincipal) == 0
      error_message = <<-EOT
        extra_policy_json combina Effect: Deny con NotPrincipal en: ${join(", ", local.custom_deny_notprincipal)}
 
        IMPACTO: un Deny con NotPrincipal deniega a TODOS menos a los listados, incluida
        tu propia cuenta e incluido kms:PutKeyPolicy. Un Deny explicito gana siempre
        sobre un Allow, asi que el statement raiz NO te protege de esto. Es el unico
        camino conocido a un lockout que el modulo no puede deshacer.
 
        SOLUCION: para denegar a principales concretos usa Deny + Principal.
      EOT
    }

    # PRECONDITION 3: Previene exposición pública de la clave
    # Detecta principals con wildcards sin conditions
    # RAZÓN: Principal: "*" sin condiciones = cualquier cuenta AWS puede usar la clave
    precondition {
      condition     = length(local.custom_wildcard_principals) == 0
      error_message = <<-EOT
        extra_policy_json concede Allow a un Principal comodin sin Condition en: ${join(", ", local.custom_wildcard_principals)}
 
        IMPACTO: cualquier cuenta de AWS del mundo puede usar esta clave.
 
        SOLUCION: nombra los principales, o acota el comodin con una condicion
        (aws:PrincipalOrgID, aws:SourceAccount, kms:ViaService).
      EOT
    }

    # PRECONDITION 4: Previene cesión de control a cuentas externas
    # Detecta kms:PutKeyPolicy concedido a principals de otras cuentas
    # RAZÓN: quien controla la policy controla la clave completamente
    precondition {
      condition     = length(local.custom_external_control) == 0
      error_message = <<-EOT
        extra_policy_json concede kms:* o kms:PutKeyPolicy a un principal externo en: ${join(", ", local.custom_external_control)}
 
        IMPACTO: un principal de otra cuenta puede reescribir la key policy entera y
        dejarte fuera de forma permanente.
 
        SOLUCION: kms:PutKeyPolicy solo para principales de esta cuenta (${local.account_id}).
        A un tercero se le conceden operaciones criptograficas, nunca el control de la
        politica.
      EOT
    }

    # Nota: no hay una precondition para Sids colisionantes ENTRE
    # service_principals (a diferencia de extra_policy_json, Validación 1).
    # No hace falta: todos los statements del módulo -incluidos los de
    # service_principals- se declaran en el mismo bloque dynamic "statement"
    # de data.aws_iam_policy_document.key, y el proveedor de AWS ya rechaza
    # ahí mismo cualquier Sid duplicado ("duplicate Sid ... Remove the Sid or
    # ensure the Sid is unique") antes de que Terraform llegue a evaluar este
    # lifecycle. Una precondition aquí sería inalcanzable: el plan ya habría
    # fallado en el data source. Ver tests/defaults.tftest.hcl.
  }
}

# ============================================================================
# KMS ALIAS - Alias principal de la clave
# ============================================================================
# Los alias permiten referenciar claves con nombres legibles en lugar de key IDs
# Ej: alias/app-prod-data en lugar de arn:aws:kms:...:key/12345678-...
# BENEFICIOS:
#   - Más fácil de recordar y usar en código/scripts
#   - Puedes cambiar la clave subyacente sin cambiar el alias
#   - Facilita rotación de claves (apuntar alias a nueva clave)
# FORMATO: alias/<tu-nombre> (el prefijo alias/ es obligatorio)
resource "aws_kms_alias" "this" {
  name          = local.alias_name        # Generado en locals.tf según var.alias_name
  target_key_id = aws_kms_key.this.key_id # Apunta a la clave creada arriba
}

# ============================================================================
# KMS ALIASES ADICIONALES - Aliases secundarios (opcional)
# ============================================================================
# Puedes crear múltiples alias para la misma clave
# Útil cuando migras de un naming scheme a otro, o para aliases por ambiente
# Ej: alias/app-data y alias/app-production-data apuntando a la misma clave
# CAMBIAR: Añade elementos a var.additional_aliases según necesites
resource "aws_kms_alias" "additional" {
  for_each = local.additional_aliases

  name          = each.value              # Valor del set de aliases adicionales
  target_key_id = aws_kms_key.this.key_id # Todas apuntan a la misma clave
}



# ============================================================================
# GUÍA DE MODIFICACIONES COMUNES
# ============================================================================
# 
# 1. CAMBIAR PERÍODO DE ELIMINACIÓN
#    Modifica var.deletion_window_in_days en variables.tf o al llamar el módulo
#    - Dev/Test: 7 días (borrado más rápido)
#    - Producción: 30 días (máxima protección)
#
# 2. AÑADIR PERMISOS PARA UN SERVICIO AWS
#    En locals.tf, añade un nuevo elemento a var.service_grants
#    Ejemplo: ["s3", "cloudwatch", "lambda"]
#    El módulo genera automáticamente los statements necesarios
#
# 3. PERMITIR USO DESDE OTRA CUENTA AWS (CROSS-ACCOUNT)
#    Usa var.extra_policy_json con un statement así:
#    {
#      "Sid": "AllowCrossAccountUse",
#      "Effect": "Allow",
#      "Principal": {"AWS": "arn:aws:iam::123456789012:root"},
#      "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"],
#      "Resource": "*",
#      "Condition": {
#        "StringEquals": {"kms:ViaService": "s3.us-east-1.amazonaws.com"}
#      }
#    }
#    NOTA: Incluye siempre una Condition para limitar el acceso
#
# 4. CREAR MÚLTIPLES ALIAS
#    Modifica var.additional_aliases en variables.tf o al llamar el módulo
#    Ejemplo: ["alias/app-data-old", "alias/legacy-encryption-key"]
#
# 5. ROTACIÓN MÁS FRECUENTE
#    Cambia var.rotation_period_in_days en variables.tf
#    - Estándar: 365 días
#    - Alta seguridad: 90 días
#    - Mínimo permitido: 90 días
#
# 6. CLAVE MULTI-REGIÓN PARA DR/HA
#    Cambia var.multi_region = true
#    Luego usa aws_kms_replica_key en otras regiones
#    COSTO: Se cobra por cada réplica (~$1/mes cada una)
#
# 7. DESHABILITAR TEMPORALMENTE LA CLAVE
#    Cambia var.is_enabled = false
#    Útil para troubleshooting sin eliminar la clave
#    Los recursos cifrados quedarán inaccesibles mientras esté deshabilitada
#
# 8. TAGS ADICIONALES
#    El módulo usa var.tags (fusionado con tags obligatorios)
#    Pasa un map con tus tags custom al llamar el módulo
#    Ejemplo: tags = { Team = "DataEngineering", CostCenter = "R&D" }
#
# ============================================================================
# TROUBLESHOOTING
# ============================================================================
#
# ERROR: "KMS key policy lockout"
#   CAUSA: La key policy no permite kms:PutKeyPolicy a nadie
#   SOLUCIÓN: Las preconditions del módulo previenen esto, pero si ocurre:
#             1. Contacta AWS Support (ellos pueden resetear la policy)
#             2. Revisa var.extra_policy_json por statements Deny problemáticos
#
# ERROR: "Access Denied" al usar la clave
#   CAUSA: IAM policies no son suficientes, necesitas permisos en key policy
#   SOLUCIÓN: 
#     - Añade el servicio a var.service_grants, o
#     - Añade un statement custom en var.extra_policy_json
#
# ERROR: Statement Sid collision
#   CAUSA: Tu extra_policy_json usa un Sid reservado por el módulo
#   SOLUCIÓN: Renombra el Sid de tu statement (ver mensaje de error)
#
# ERROR: "Principal *.* is not valid"
#   CAUSA: Intentas usar Principal: "*" sin Condition
#   SOLUCIÓN: Usa un Principal específico o añade Conditions restrictivas
#
# ============================================================================
