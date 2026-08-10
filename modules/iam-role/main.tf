###############################################################################
# Política de confianza
#
# Define quiénes pueden asumir el rol. Una política de permisos segura no es
# suficiente si entidades no autorizadas pueden asumir el rol.
#
# Se utiliza aws_iam_policy_document para validar la política durante el plan
# y generar un JSON consistente, evitando diferencias innecesarias por formato.
###############################################################################

data "aws_partition" "current" {}

data "aws_iam_policy_document" "assume_role" {
  # Principales de servicio: EC2, Lambda, ECS Tasks, etc.
  dynamic "statement" {
    for_each = local.has_service_trust ? [1] : []

    content {
      sid     = "ConfianzaDeServicios"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "Service"
        identifiers = var.trusted_services
      }
      # Restringe el acceso a la cuenta de origen para reducir el riesgo de
      # confused deputy cuando el servicio admite aws:SourceAccount.
      dynamic "condition" {
        for_each = var.trusted_source_account != null ? [1] : []

        content {
          test     = "StringEquals"
          variable = "aws:SourceAccount"
          values   = [var.trusted_source_account]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = local.has_account_trust ? [1] : []

    content {
      sid     = "ConfianzaCrossAccount"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = local.trusted_account_arns
      }

      condition {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.external_id]
      }
    }
  }
}


###############################################################################
# Rol
#
# name, no name_prefix - al reves que el modulo sg.
#
# Alli el name_prefix era obligatorio porque create_before_destroy hacia
# convivir dos security groups y los nombres debian ser unicos. En IAM no
# existe ese problema.
#
# Y hay una razon positiva para el nombre exacto: los nombres de rol aparecen
# en politicas de confianza escritas en OTRAS cuentas, en runbooks y en
# documentacion. Un sufijo aleatorio los vuelve inmanejables.
###############################################################################

resource "aws_iam_role" "this" {
  name                  = var.name
  description           = var.description
  path                  = var.path
  max_session_duration  = var.max_session_duration
  assume_role_policy    = data.aws_iam_policy_document.assume_role.json
  permissions_boundary  = var.permissions_boundary_arn
  force_detach_policies = true

  tags = merge(
    local.tags,
    { Name = var.name }
  )

  ###########################################################################
  # Las comprobaciones que justifican que este modulo exista.
  #
  # Van en precondition y no en validation porque necesitan el jsondecode y la
  # normalizacion de locals.tf, y un bloque validation solo puede referenciar
  # variables. Siguen disparandose en plan, que es lo que importa: fallar en
  # plan es cien veces mas barato que fallar en apply.
  ###########################################################################

  lifecycle {
    precondition {
      condition     = length(local.wildcard_admin_statements) == 0
      error_message = "Politica con Action '*' sobre Resource '*': concede acceso total a la cuenta. Statements afectados: ${join(", ", local.wildcard_admin_statements)}. Acota las acciones o los recursos."
    }

    precondition {
      condition     = length(local.unrestricted_passrole_statements) == 0
      error_message = "iam:PassRole sobre Resource '*' sin condicion: es el vector de escalada de privilegios mas comun de AWS, porque permite pasar el rol de administrador a un servicio y ejecutar codigo con el. Statements afectados: ${join(", ", local.unrestricted_passrole_statements)}. Restringe el Resource a los ARN de rol concretos."
    }

    precondition {
      condition     = length(local.unrestricted_assumerole_statements) == 0
      error_message = "sts:AssumeRole sobre Resource '*' sin condicion: permite pivotar a cualquier rol de la cuenta. Statements afectados: ${join(", ", local.unrestricted_assumerole_statements)}. Restringe el Resource a los roles que realmente hay que asumir."
    }
  }
}


###############################################################################
# Políticas Managed adjuntas al rol
#
# Se usa aws_iam_role_policy_attachment (NO aws_iam_policy_attachment):
#
#   - aws_iam_policy_attachment es para adjuntar a múltiples entidades
#     (usuarios, grupos, roles) y puede causar conflictos si otras partes del
#     código gestionan las mismas adjunciones.
#
#   - aws_iam_role_policy_attachment es específico para roles y más seguro
#     en módulos porque gestiona la relación rol-política de forma exclusiva.
###############################################################################

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

###############################################################################
# Políticas inline del rol
#
# Se crean como inline para que se borren automáticamente con el rol y no
# queden políticas huérfanas acumulándose en la cuenta.
###############################################################################

resource "aws_iam_role_policy" "this" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.name
  policy = each.value
}

###############################################################################
# Instance profile
#
# Solo lo necesitan EC2 y los grupos de autoescalado. Para Lambda, ECS o RDS
# sobra, y crearlo por defecto seria ensuciar la cuenta con recursos que nadie
# usa.
###############################################################################

resource "aws_iam_instance_profile" "this" {
  count = var.create_instance_profile ? 1 : 0

  name = var.name
  path = var.path
  role = aws_iam_role.this.name

  tags = merge(
    local.tags,
    { Name = var.name }
  )

}