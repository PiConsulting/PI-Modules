locals {
  tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "iam-role"
    }
  )

  ###########################################################################
  # Relación de confianza
  #
  # El ARN utiliza la partición real de AWS. En GovCloud es "aws-us-gov" y
  # en China "aws-cn". Usar una partición incorrecta genera un ARN inválido.
  ###########################################################################

  partition = data.aws_partition.current.partition

  has_service_trust = length(var.trusted_services) > 0
  has_account_trust = length(var.trusted_account_ids) > 0

  trusted_account_arns = [
    for a in var.trusted_account_ids : "arn:${local.partition}:iam::${a}:root"
  ]

  has_permissions_boundary = var.permissions_boundary_arn != null

  ###########################################################################
  # Normalización de las políticas inline
  #
  # Se normalizan las diferentes estructuras que puede tener una política IAM
  # para poder procesarlas de forma consistente.
  #
  # Dos casos requieren un tratamiento especial:
  #
  #   1. Statement puede ser un objeto o una lista de objetos.
  #      Si Statement.Effect existe, se interpreta como un único statement.
  #
  #   2. Action y Resource pueden ser una cadena o una lista de valores.
  #      Se detecta el tipo antes de normalizarlos para evitar errores con
  #      estructuras diferentes.
  #
  # No se utiliza tolist() para detectar listas, ya que puede fallar con
  # colecciones que contienen objetos con atributos diferentes.
  ###########################################################################

  decoded_policies = {
    for k, v in var.inline_policies : k => jsondecode(v)
  }

  statements_by_policy = {
    for k, doc in local.decoded_policies : k => (
      can(doc.Statement.Effect) ? [doc.Statement] : doc.Statement
    )
  }

  all_statements = flatten([
    for k, statements in local.statements_by_policy : [
      for s in statements : merge(s, { _policy = k })
    ]
  ])

  normalized_statements = [
    for s in local.all_statements : {
      policy        = s._policy
      sid           = try(s.Sid, "")
      effect        = try(s.Effect, "Allow")
      actions       = can(tostring(try(s.Action, []))) ? [tostring(s.Action)] : try(s.Action, [])
      resources     = can(tostring(try(s.Resource, []))) ? [tostring(s.Resource)] : try(s.Resource, [])
      has_condition = can(s.Condition)
    }
  ]

  ###########################################################################
  # Comprobaciones de políticas
  #
  # Las comprobaciones se calculan aquí y se aplican mediante precondition
  # en main.tf. No pueden utilizarse en validation porque dependen de
  # jsondecode y de la normalización de las políticas.
  #
  # Las preconditions se evalúan durante el plan, permitiendo detectar errores
  # antes de aplicar los cambios.
  ###########################################################################

  # Acceso total a la cuenta. El equivalente IAM del 0.0.0.0/0 en un security
  # group, pero sin nada visual que lo delate.
  wildcard_admin_statements = [
    for s in local.normalized_statements : "${s.policy}/${s.sid}"
    if s.effect == "Allow" && contains(s.actions, "*") && contains(s.resources, "*")
  ]

  # iam:PassRole sin acotar es el vector de escalada mas comun de AWS: si puedo
  # pasar cualquier rol a un servicio, puedo pasarle el rol de administrador y
  # ejecutar codigo con el.
  unrestricted_passrole_statements = [
    for s in local.normalized_statements : "${s.policy}/${s.sid}"
    if s.effect == "Allow"
    && anytrue([for a in s.actions : lower(a) == "iam:passrole" || a == "*" || lower(a) == "iam:*"])
    && contains(s.resources, "*")
    && !s.has_condition
  ]

  # sts:AssumeRole sobre "*" permite pivotar a cualquier rol de la cuenta.
  unrestricted_assumerole_statements = [
    for s in local.normalized_statements : "${s.policy}/${s.sid}"
    if s.effect == "Allow"
    && anytrue([for a in s.actions : lower(a) == "sts:assumerole" || a == "*" || lower(a) == "sts:*"])
    && contains(s.resources, "*")
    && !s.has_condition
  ]
}