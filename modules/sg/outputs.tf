
output "id" {
  description = "ID del security group. Es el output que sostiene el encadenado entre capas: se pasa a source_security_group_ids de otra invocacion de este mismo modulo, o a los modulos de computo y datos."
  value       = aws_security_group.this.id
}

output "arn" {
  description = "ARN del security group. Para politicas IAM que restringen por grupo."
  value       = aws_security_group.this.arn
}

output "name" {
  description = "Nombre real generado por AWS a partir del name_prefix. No coincide con var.name: lleva un sufijo aleatorio, consecuencia necesaria de create_before_destroy."
  value       = aws_security_group.this.name
}

output "vpc_id" {
  description = "VPC donde vive el security group. Se devuelve para que los modulos consumidores puedan afirmar que estan en la misma red sin volver a resolverlo."
  value       = aws_security_group.this.vpc_id
}


output "ingress_rule_ids" {
  description = "Mapa de clave aplanada a ID de regla de entrada. Para auditoria y para politicas que referencian una regla concreta."
  value       = { for k, v in aws_vpc_security_group_ingress_rule.this : k => v.id }
}

output "egress_rule_ids" {
  description = "Mapa de clave a ID de regla de salida. Cuando allow_all_egress es true contiene una unica entrada, allow-all."
  value = merge(
    { for k, v in aws_vpc_security_group_egress_rule.this : k => v.id },
    var.allow_all_egress ? { "allow-all" = aws_vpc_security_group_egress_rule.allow_all[0].id } : {}
  )
}


output "allow_all_egress" {
  description = "Politica de salida aplicada realmente. Se devuelve para que una revision de arquitectura o una politica automatizada pueda afirmar sobre ella sin leer el codigo del consumidor."
  value       = var.allow_all_egress
}


output "ingress_rule_count" {
  description = "Numero de reglas de entrada creadas. Util para detectar grupos que han ido creciendo sin control."
  value       = length(aws_vpc_security_group_ingress_rule.this)
}