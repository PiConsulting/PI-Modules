###############################################################################
# Lógica central del módulo
#
# Este archivo concentra toda la lógica de negocio: construcción de nombres,
# composición de la key policy, y normalización de políticas personalizadas.
# main.tf solo debe contener recursos y preconditions que lean estos locales.
#
# ── Reglas de tipado para evitar "inconsistent conditional result types" ──
#
# Estas reglas nacieron de bugs reales con políticas IAM irregulares:
#
#   1. Normalizar JSON irregular → usa flatten([x])
#      flatten() no aplana objetos pero sí aplana listas, que es justo lo que
#      necesitamos para estructuras IAM donde Statement puede ser objeto o array.
#
#   2. Elementos condicionales → usa [for ... if cond] en lugar de ternarios
#      EVITA:  cond ? [{ ... }] : []
#      USA:    [for x in [...] : { ... } if cond]
#      
#      La comprensión produce 0 o 1 elementos sin forzar a Terraform a unificar
#      dos ramas de tipos distintos.
#
# ── Dependencias ──
#   data.aws_partition.current
#   data.aws_caller_identity.current
###############################################################################

locals {
  # ── Identidad de la cuenta ──
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  root_arn   = "arn:${local.partition}:iam::${local.account_id}:root"

  # ── Naming ──
  # Las claves KMS no tienen nombre, solo UUID. key_name solo existe para tags
  # y legibilidad en consola. El identificador real es el alias.
  #
  # Los alias se prefijan por entorno (alias/dev/..., alias/prod/...) porque
  # el espacio de nombres de alias es plano por región: sin prefijo, dev y prod
  # en la misma cuenta colisionarían.
  key_name   = "${var.environment}-${var.name}-kms"
  alias_name = "alias/${var.environment}/${var.name}"

  # Mapa en lugar de lista: eliminar un alias del medio no fuerza recreación
  # de los posteriores (los índices de lista cambiarían, los keys de mapa no)
  additional_aliases = {
    for a in var.additional_aliases : a => "alias/${var.environment}/${a}"
  }

  # ── Tags estándar ──
  tags = merge(
    var.tags,
    {
      Name        = local.key_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "kms"
    }
  )

  # ── Statement IDs (Sid) del módulo ──
  # Los Sid solo admiten caracteres alfanuméricos (sin guiones ni puntos).
  # 
  # Esta lista protege contra lockout silencioso: aws_iam_policy_document fusiona
  # statements por Sid, así que un extra_policy_json que reutilice
  # "EnableIAMUserPermissions" SOBRESCRIBE el statement raíz sin error visible.
  sid_root           = "EnableIAMUserPermissions"
  sid_administration = "KeyAdministration"
  sid_usage_crypto   = "KeyUsageCryptographic"
  sid_usage_grants   = "KeyUsageGrants"
  service_sid_prefix = "ServiceUsage"

  reserved_sids = [
    local.sid_root,
    local.sid_administration,
    local.sid_usage_crypto,
    local.sid_usage_grants,
  ]

  # Deriva un Sid por servicio: logs.us-east-1.amazonaws.com → ServiceUsageLogsUsEast1.
  # NO son únicos por construcción: dos principales sintácticamente distintos
  # pueden normalizar al mismo Sid (p.ej. separados por "." o "-"). No hace
  # falta detectarlo aquí: todos estos Sids terminan en el mismo bloque
  # dynamic "statement" de data.aws_iam_policy_document.key (main.tf), y el
  # proveedor de AWS ya rechaza ahí cualquier duplicado con su propio error
  # ("duplicate Sid"). Ver la nota junto a las preconditions en main.tf.
  service_sids = {
    for p, _ in var.service_principals :
    p => "${local.service_sid_prefix}${replace(title(replace(trimsuffix(p, ".amazonaws.com"), "/[^a-zA-Z0-9]/", " ")), " ", "")}"
  }

  # ── Permisos de administración: ciclo de vida SIN operaciones criptográficas ──
  #
  # Se enumeran explícitamente en lugar de usar wildcards (kms:Create*, kms:Get*)
  # por una razón crítica: kms:Create* incluye kms:CreateGrant, y con CreateGrant
  # un administrador podría auto-concederse kms:Decrypt y leer datos cifrados.
  # Eso rompería la separación de funciones que promete el módulo.
  #
  # kms:PutKeyPolicy SÍ está incluido: garantiza que el anti-lockout funcione
  # y que alguien pueda corregir la política sin abrir caso con AWS Support.
  key_administrator_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:ReplicateKey",
    "kms:RevokeGrant",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
    "kms:UpdatePrimaryRegion",
  ]

  # ── Permisos de uso: operaciones criptográficas ──
  key_user_crypto_actions = [
    "kms:DescribeKey",
    "kms:Decrypt",
    "kms:Encrypt",
    "kms:GenerateDataKey*",
    "kms:ReEncrypt*",
  ]

  # ── Permisos de grants: necesarios para servicios integrados de AWS ──
  # Sin este bloque:
  #   - Auto Scaling Groups con EBS cifrado no lanzan instancias
  #   - RDS no puede crear clusters cifrados
  #   - Lambda no puede configurar cifrado en reposo
  # Los errores resultantes NO mencionan la palabra "grant" explícitamente.
  key_user_grant_actions = [
    "kms:CreateGrant",
    "kms:ListGrants",
    "kms:RevokeGrant"
  ]

  # ── Condiciones para principales de servicio (protección confused deputy) ──
  #
  # aws:SourceAccount se inyecta SIEMPRE (sin variable que lo controle).
  # Sin esta condición, un principal de servicio actúa en nombre de CUALQUIERA
  # que lo invoque, incluyendo recursos de otras cuentas (confused deputy attack).
  #
  # Todas las condiciones opcionales usan [for ... if] en lugar de ternarios
  # para evitar unificación de tuplas de distintas longitudes.

  service_principal_conditions = {
    for p, cfg in var.service_principals : p => concat(

      # Condición obligatoria: cierra confused deputy
      [{
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }],

      # Condición kms:ViaService: restringe que la clave solo se use a través del servicio especificado
      [for v in ["kms:ViaService"] : {
        test     = "StringEquals"
        variable = v
        values   = cfg.via_service
      } if length(cfg.via_service) > 0],

      # ArnLike (no ArnEquals): los ARNs de origen suelen incluir wildcards
      [for v in ["aws:SourceArn"] : {
        test     = "ArnLike"
        variable = v
        values   = cfg.source_arns
      } if length(cfg.source_arns) > 0],

      # Una condición por cada clave del encryption context
      [for k, v in cfg.encryption_context : {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:${k}"
        values   = [v]
      }],
    )
  }

  # ── Policy Statements ──
  #
  # Todos los statements tienen la misma estructura (sid, effect, principals,
  # actions, resources, conditions) para que el concat final no fuerce a Terraform
  # a unificar tipos distintos.
  #
  # Resource = "*" significa "esta clave" (no "toda la cuenta"). En key policies
  # no hay otro Resource posible.

  # ── Statement raíz: delegación en IAM (OBLIGATORIO) ──
  #
  # Sin este statement, SOLO los principales listados en la key policy tienen
  # acceso, y kms:PutKeyPolicy también se rige por ella: si la lista está mal,
  # nadie puede usar la clave NI editar su política (lockout total).
  #
  # Este statement NO concede acceso por sí solo. Habilita que las políticas IAM
  # de la cuenta puedan conceder acceso. Sin política IAM adicional, ningún
  # principal puede usar la clave. Funciona como permissions boundary: un techo
  # que delega, no una concesión directa.
  statements_root = [{
    sid        = local.sid_root
    effect     = "Allow"
    principals = [{ type = "AWS", identifiers = [local.root_arn] }]
    actions    = ["kms:*"]
    resources  = ["*"]
    conditions = []
  }]

  statements_administration = [
    for enabled in [length(var.key_administrators) > 0] : {
      sid        = local.sid_administration
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = var.key_administrators }]
      actions    = local.key_administrator_actions
      resources  = ["*"]
      conditions = []
    } if enabled
  ]

  statements_usage_crypto = [
    for enabled in [length(var.key_users) > 0] : {
      sid        = local.sid_usage_crypto
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = var.key_users }]
      actions    = local.key_user_crypto_actions
      resources  = ["*"]
      conditions = []
    } if enabled
  ]

  statements_usage_grants = [
    for enabled in [length(var.key_users) > 0] : {
      sid        = local.sid_usage_grants
      effect     = "Allow"
      principals = [{ type = "AWS", identifiers = var.key_users }]
      actions    = local.key_user_grant_actions
      resources  = ["*"]
      conditions = [{
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }]
    } if enabled
  ]

  # kms:CreateGrant se separa del resto de actions de cada service principal.
  # Una condition se evalúa contra TODAS las actions de su statement: si
  # CreateGrant compartiera statement con Decrypt/Encrypt bajo la condición
  # kms:GrantIsForAWSResource, esas actions dejarían de matchear (esa clave de
  # condición no existe fuera de CreateGrant) y el resto del statement
  # quedaría bloqueado. Mismo motivo por el que key_users genera dos
  # statements en vez de uno.
  service_actions_non_grant = {
    for p, cfg in var.service_principals :
    p => [for a in cfg.actions : a if lower(a) != "kms:creategrant"]
  }

  service_actions_grant = {
    for p, cfg in var.service_principals :
    p => [for a in cfg.actions : a if lower(a) == "kms:creategrant"]
  }

  statements_services = [
    for p, cfg in var.service_principals : {
      sid        = local.service_sids[p]
      effect     = "Allow"
      principals = [{ type = "Service", identifiers = [p] }]
      actions    = local.service_actions_non_grant[p]
      resources  = ["*"]
      conditions = local.service_principal_conditions[p]
    } if length(local.service_actions_non_grant[p]) > 0
  ]

  statements_services_grants = [
    for p, cfg in var.service_principals : {
      sid        = "${local.service_sids[p]}Grants"
      effect     = "Allow"
      principals = [{ type = "Service", identifiers = [p] }]
      actions    = local.service_actions_grant[p]
      resources  = ["*"]
      conditions = concat(local.service_principal_conditions[p], [{
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }])
    } if length(local.service_actions_grant[p]) > 0
  ]

  # ── Composición final de la política ──
  # El orden es significativo: el statement raíz siempre primero
  policy_statements = concat(
    local.statements_root,
    local.statements_administration,
    local.statements_usage_crypto,
    local.statements_usage_grants,
    local.statements_services,
    local.statements_services_grants,
  )

  # ── Normalización de extra_policy_json ──
  #
  # jsondecode() de una política IAM devuelve estructuras irregulares:
  #   Statement         → objeto suelto O lista de objetos
  #   Action / Resource → cadena O lista de cadenas
  #   Principal         → cadena "*" O { AWS = ... } O { Service = ... }
  #                       (y cada valor puede ser cadena O lista)
  #
  # Solución: flatten([x]) en lugar de ternarios.
  # flatten() no aplana objetos pero SÍ aplana listas, que es justo lo que
  # necesitamos. El intento original can(tolist(x)) ? x : [x] funcionaba con
  # un statement pero fallaba con dos.

  # Ternario sobre strings (no sobre objetos): ambas ramas son tuple([]) y
  # tuple([string]), unifican a list(string) sin ambigüedad
  custom_policy_docs = [
    for j in(var.extra_policy_json == null ? [] : [var.extra_policy_json]) : jsondecode(j)
  ]

  # flatten([doc.Statement]) normaliza:
  #   objeto suelto → [obj]          (flatten no aplana objetos)
  #   lista de N    → [o1, ..., oN]  (flatten sí aplana listas)
  custom_statements_raw = flatten([
    for doc in local.custom_policy_docs : flatten([try(doc.Statement, [])])
  ])

  custom_statements = [
    for s in local.custom_statements_raw : {
      sid       = try(s.Sid, "")
      effect    = try(s.Effect, "Allow")
      actions   = flatten([try(s.Action, [])])
      resources = flatten([try(s.Resource, [])])

      has_principal    = can(s.Principal)
      has_notprincipal = can(s.NotPrincipal)

      # length(), no can(): can(s.Condition) solo comprueba que la CLAVE exista.
      # Un statement con "Condition": {} (objeto vacio pero presente) pasaria
      # can() como true y evadiria la precondition 3 sin restringir nada de
      # verdad. length() exige al menos un operador real dentro de Condition.
      has_condition = length(try(s.Condition, {})) > 0

      # try(tostring(...)) captura Principal = "*" como string y devuelve ""
      # cuando Principal es objeto (tostring falla en objetos).
      # compact() limpia esos "" vacíos, dejando una lista homogénea de strings.
      principal_ids = compact(flatten([
        [try(tostring(s.Principal), "")],
        try(s.Principal.AWS, []),
        try(s.Principal.Service, []),
        try(s.Principal.Federated, []),
      ]))
    }
  ]

  # ── Validaciones de seguridad para preconditions de main.tf ──
  #
  # Se calculan aquí (no en validations de variables) porque dependen de
  # jsondecode() y normalización. Las preconditions se evalúan en plan,
  # así que no perdemos early-fail.

  # ── Validación 1: Colisión de Sid ──
  # LOCKOUT SILENCIOSO: aws_iam_policy_document fusiona por Sid, así que
  # reutilizar "EnableIAMUserPermissions" reemplaza el statement raíz sin error.
  custom_sid_collisions = [
    for s in local.custom_statements : s.sid
    if contains(local.reserved_sids, s.sid) || startswith(s.sid, local.service_sid_prefix)
  ]

  # ── Validación 2: Deny + NotPrincipal ──
  # Vector de lockout que SOBREVIVE al statement raíz: deniega a todos excepto
  # los listados, incluida tu propia cuenta y kms:PutKeyPolicy. Deny gana siempre.
  custom_deny_notprincipal = [
    for s in local.custom_statements : coalesce(s.sid, "(statement sin Sid)")
    if s.effect == "Deny" && s.has_notprincipal
  ]

  # ── Validación 3: Principal wildcard sin condición ──
  # La clave quedaría utilizable por cualquier cuenta de AWS del mundo.
  custom_wildcard_principals = [
    for s in local.custom_statements : coalesce(s.sid, "(statement sin Sid)")
    if s.effect == "Allow" && contains(s.principal_ids, "*") && !s.has_condition
  ]

  # ── Validación 4: Control cedido a terceros ──
  # Con kms:PutKeyPolicy, un principal externo puede reescribir la política
  # completa y bloquearte el acceso.
  custom_external_control = [
    for s in local.custom_statements : coalesce(s.sid, "(statement sin Sid)")
    if s.effect == "Allow"
    && anytrue([for a in s.actions : contains(["kms:*", "kms:putkeypolicy"], lower(a))])
    && anytrue([
      for p in s.principal_ids :
      p == "*" || (
        can(regex("^arn:aws[a-z-]*:iam::", p)) &&
        !can(regex("^arn:aws[a-z-]*:iam::${local.account_id}:", p))
      )
    ])
  ]

  # ── Postura del módulo (observabilidad para auditoría) ──
  #
  # Similar a vpc (nat_gateway_mode), sg (allow_all_egress), iam-role
  # (has_permissions_boundary). Permite auditar "en prod ninguna clave tiene
  # service principals sin acotar" sin leer el código del consumidor.
  has_policy_override = var.extra_policy_json != null

  # Service principals que solo tienen la condición mínima (aws:SourceAccount).
  # No es error: esa condición ya cierra confused deputy. Pero en prod este
  # array debería estar vacío (principals deberían tener via_service,
  # source_arns o encryption_context adicionales).
  unscoped_service_principals = sort([
    for p, cfg in var.service_principals : p
    if length(cfg.via_service) == 0
    && length(cfg.source_arns) == 0
    && length(cfg.encryption_context) == 0
  ])
}