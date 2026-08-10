###############################################################################
# Identidad del rol
###############################################################################

output "arn" {
  description = "ARN del rol. Es el output que consumen casi todos los modulos: ECS lo recibe como task_role_arn, Lambda como role, RDS como monitoring_role_arn."
  value       = aws_iam_role.this.arn
}

output "name" {
  description = "Nombre del rol. Se usa al escribir politicas de confianza en otras cuentas y en runbooks, y por eso el modulo usa name exacto en lugar de name_prefix."
  value       = aws_iam_role.this.name
}

output "id" {
  description = "ID del rol, que en IAM coincide con el nombre. Se expone por costumbre de otros modulos del ecosistema."
  value       = aws_iam_role.this.id
}

output "unique_id" {
  description = "Identificador interno estable del rol (AROA...). Util en condiciones aws:userid, que sobreviven a que el rol se renombre."
  value       = aws_iam_role.this.unique_id
}

###############################################################################
# Instance profile
###############################################################################

output "instance_profile_arn" {
  description = "ARN del instance profile, o null si no se creo. Lo consumen los modulos de EC2 y de autoescalado."
  value       = try(aws_iam_instance_profile.this[0].arn, null)
}

output "instance_profile_name" {
  description = "Nombre del instance profile, o null si no se creo."
  value       = try(aws_iam_instance_profile.this[0].name, null)
}

###############################################################################
# Auditoria
###############################################################################

output "assume_role_policy_json" {
  description = "Politica de confianza construida por el modulo. Permite revisar quien puede asumir el rol en un plan o en un PR, sin entrar a la consola. Contiene el external_id en claro cuando hay confianza cross-account."
  value       = data.aws_iam_policy_document.assume_role.json
}

output "inline_policy_names" {
  description = "Nombres de las politicas inline creadas."
  value       = keys(aws_iam_role_policy.this)
}

output "attached_managed_policy_arns" {
  description = "ARNs de politicas gestionadas realmente adjuntadas. Se devuelve para poder auditar sin leer el codigo del consumidor."
  value       = [for a in aws_iam_role_policy_attachment.this : a.policy_arn]
}

###############################################################################
# Postura
#
# Mismo patron que nat_gateway_mode en vpc y allow_all_egress en sg: se
# devuelve la decision, no solo los identificadores, para que una politica
# automatizada pueda afirmar "en prod, todo rol tiene boundary" sin leer el
# codigo de cada consumidor.
###############################################################################

output "has_permissions_boundary" {
  description = "Si el rol lleva limite de permisos. False significa que se uso la exencion documentada."
  value       = local.has_permissions_boundary
}

output "boundary_exempt_reason" {
  description = "Justificacion de la exencion de limite de permisos, o null si el rol si lo tiene. Es el campo que revisa una auditoria."
  value       = local.has_permissions_boundary ? null : var.boundary_exempt_reason
}

output "max_session_duration" {
  description = "Duracion maxima de sesion aplicada, en segundos."
  value       = aws_iam_role.this.max_session_duration
}