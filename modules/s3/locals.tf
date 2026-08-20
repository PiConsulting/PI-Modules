locals {
  account_id = data.aws_caller_identity.current.account_id
  #--- TAGS ----
  tags = merge(
    var.tags,
    {
      Name        = var.bucket_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "s3"
    }
  )

  # ---- Cifrado ----
  sse_algorithm = var.kms_key_arn != null ? "aws:kms" : "AES256"
  # bucket_key_enabled solo tiene sentido (reduce costos de llamadas a KMS)
  bucket_key_enabled = var.kms_key_arn != null

  # ---- Sids reservados del modulo ----
  # alguno de estos Sids, aws_iam_policy_document lo fusiona SIN error y
  # pisa el statement del módulo en silencio. Por eso Validación 1 (más
  # abajo) los rechaza en plan.
  sid_deny_insecure_transport = "DenyInsecureTransport"

  reserved_sids = [
    local.sid_deny_insecure_transport,
  ]

  # ---- custom_bucket_policy ----
  # 
  # jsondecode() de una politica IAM devuelve estructuras irregulares:
  # Statement --> objeto suelto O lista de objetos
  # Action / Resource --> cadena O lista de cadenas
  # Principal --> cadena "*" o { AWS = ... } tambien { Service = ... }
  # Mismo bug de kms si se usa un temario: flatten([x]) en vez de cond ? [x] : x

  custom_policy_docs = [
    for j in(var.custom_bucket_policy == null ? [] : [var.custom_bucket_policy]) : jsondecode(j)
  ]

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

      # length(), no can(): un "Condition": {} presente pero vacio no cuenta
      # como condicion real (mismo fix que ya aplicaste en kms).
      has_condition = length(try(s.Condition, {})) > 0

      principal_ids = compact(flatten([
        [try(tostring(s.Principal), "")],
        try(s.Principal.AWS, []),
        try(s.Principal.Service, []),
        try(s.Principal.Federated, []),
      ]))

    }
  ]

  # --- validaciones de seguridad para preconditions en main.tf ---

  # validacion 1: colision de sid con los reservados del modulo
  custom_sid_collisions = [
    for s in local.custom_statements : s.sid
    if contains(local.reserved_sids, s.sid)
  ]

  # Validación 2: Deny + NotPrincipal — lockout que sobrevive a cualquier
  # statement del módulo, porque Deny siempre gana sobre Allow.
  custom_deny_notprincipal = [
    for s in local.custom_statements : coalesce(s.sid, "(statement sin Sid)")
    if s.effect == "Deny" && s.has_notprincipal
  ]

  # Validación 3: Principal comodín sin condición — el bucket quedaría
  # utilizable por cualquier cuenta de AWS, el mismo agujero que
  # public_access_block cierra por otra via.
  custom_wildcard_principals = [
    for s in local.custom_statements : coalesce(s.sid, "(statement sin Sid)")
    if s.effect == "Allow" && contains(s.principal_ids, "*") && !s.has_condition
  ]

  # Validación 4: s3:PutBucketPolicy (o s3:*) cedido a un principal externo
  # a la cuenta — equivalente al kms:PutKeyPolicy externo que ya chequea kms.
  # Depende de local.account_id, que declaramos en main.tf via
  # data.aws_caller_identity.current
  custom_external_control = [
    for s in local.custom_statements : coalesce(s.sid, "(statement sin Sid)")
    if s.effect == "Allow"
    && anytrue([for a in s.actions : contains(["s3:*", "s3:putbucketpolicy"], lower(a))])
    && anytrue([
      for p in s.principal_ids :
      p == "*" || (
        can(regex("^arn:aws[a-z-]*:iam::", p)) &&
        !can(regex("^arn:aws[a-z-]*:iam::${local.account_id}:", p))
      )
    ])
  ]
}