# ── Identificadores ──
output "key_id" {
  description = "ID único de la clave KMS (UUID)"
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "ARN completo de la clave KMS"
  value       = aws_kms_key.this.arn
}

output "alias_name" {
  description = "Nombre del alias principal (alias/<entorno>/<nombre>)"
  value       = aws_kms_alias.this.name
}

output "alias_arn" {
  description = "ARN del alias principal"
  value       = aws_kms_alias.this.arn
}

output "additional_alias_names" {
  description = "Map de alias adicionales creados"
  value       = { for k, v in aws_kms_alias.additional : k => v.name }
}

# ── Atributos de la clave ──
output "is_enabled" {
  description = "Si la clave está habilitada para operaciones criptográficas"
  value       = aws_kms_key.this.is_enabled
}

output "rotation_enabled" {
  description = "Si la rotación automática está habilitada (siempre true en este módulo)"
  value       = aws_kms_key.this.enable_key_rotation
}

output "rotation_period_in_days" {
  description = "Periodo de rotación automática en días"
  value       = aws_kms_key.this.rotation_period_in_days
}

output "multi_region" {
  description = "Si la clave es multirregión"
  value       = aws_kms_key.this.multi_region
}

# ── Postura (observabilidad para auditoría) ──
output "has_policy_override" {
  description = "Si se proporcionó extra_policy_json. Indica que hay statements custom además de los modelados"
  value       = local.has_policy_override
}

output "unscoped_service_principals" {
  description = "Service principals que solo tienen aws:SourceAccount (sin via_service, source_arns o encryption_context). En prod debería estar vacío"
  value       = local.unscoped_service_principals
}

output "key_administrators_count" {
  description = "Número de principales con permisos de administración (lifecycle, no crypto)"
  value       = length(var.key_administrators)
}

output "key_users_count" {
  description = "Número de principales con permisos criptográficos (Encrypt, Decrypt, etc.)"
  value       = length(var.key_users)
}

output "service_principals_count" {
  description = "Número de service principals configurados"
  value       = length(var.service_principals)
}
