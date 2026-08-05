###############################################################################
# VPC
###############################################################################

output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN de la VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "Bloque CIDR IPv4 principal de la VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_secondary_cidr_blocks" {
  description = "Bloques CIDR IPv4 secundarios asociados con la VPC."
  value       = [for a in aws_vpc_ipv4_cidr_block_association.secondary : a.cidr_block]
}

output "vpc_all_cidr_blocks" {
  description = "Todos los bloques CIDR de la VPC. Consumir esto en módulos de grupos de seguridad en lugar de re-declarar rangos."
  value       = local.all_vpc_cidrs
}

output "default_security_group_id" {
  description = "ID del grupo de seguridad por defecto de la VPC. Expuesto para que las verificaciones de políticas puedan afirmar que no tiene reglas - no está destinado a ser adjuntado a nada."
  value       = aws_vpc.this.default_security_group_id
}

output "availability_zones" {
  description = "Zonas de disponibilidad que abarca la VPC, en el orden utilizado para cada salida de lista de este módulo."
  value       = local.azs
}

###############################################################################
# Subnets
###############################################################################

output "public_subnet_ids" {
  description = "IDs de las subredes públicas, ordenados por availability_zones."
  value       = [for k in local.public_subnet_keys : aws_subnet.public[k].id]
}

output "public_subnet_cidr_blocks" {
  description = "Bloques CIDR de las subredes públicas, ordenados por availability_zones."
  value       = [for k in local.public_subnet_keys : aws_subnet.public[k].cidr_block]
}

output "public_subnets_by_az" {
  description = "Mapa de zona de disponibilidad a ID de subred pública. Usar esto cuando un recurso debe estar anclado a una AZ específica."
  value       = { for k, v in aws_subnet.public : k => v.id }
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas, ordenados por availability_zones. Esta es la ubicación por defecto para cómputo."
  value       = [for k in local.private_subnet_keys : aws_subnet.private[k].id]
}

output "private_subnet_cidr_blocks" {
  description = "Bloques CIDR de las subredes privadas, ordenados por availability_zones."
  value       = [for k in local.private_subnet_keys : aws_subnet.private[k].cidr_block]
}

output "private_subnets_by_az" {
  description = "Mapa de zona de disponibilidad a ID de subred privada."
  value       = { for k, v in aws_subnet.private : k => v.id }
}

output "database_subnet_ids" {
  description = "IDs de las subredes de base de datos, ordenados por availability_zones."
  value       = [for k in local.database_subnet_keys : aws_subnet.database[k].id]
}

output "database_subnet_cidr_blocks" {
  description = "Bloques CIDR de las subredes de base de datos, ordenados por availability_zones."
  value       = [for k in local.database_subnet_keys : aws_subnet.database[k].cidr_block]
}

output "database_subnet_group_name" {
  description = "Nombre del grupo de subredes de BD, o null cuando no se crea. Alimentar esto directamente al módulo RDS/Aurora."
  value       = try(aws_db_subnet_group.this[0].name, null)
}

###############################################################################
# Routing and egress
###############################################################################

output "internet_gateway_id" {
  description = "ID del internet gateway, o null cuando no existe capa pública."
  value       = try(aws_internet_gateway.this[0].id, null)
}

output "public_route_table_id" {
  description = "ID de la tabla de rutas pública, o null cuando no existe capa pública."
  value       = try(aws_route_table.public[0].id, null)
}

output "private_route_table_ids" {
  description = "IDs de las tablas de rutas privadas."
  value       = [for k in local.private_rt_keys : aws_route_table.private[k].id]
}

output "database_route_table_id" {
  description = "ID de la tabla de rutas de base de datos, o null cuando no existe capa de base de datos."
  value       = try(aws_route_table.database[0].id, null)
}

output "nat_gateway_ids" {
  description = "IDs de los NAT gateways."
  value       = [for az in local.nat_azs : aws_nat_gateway.this[az].id]
}

output "nat_gateway_public_ips" {
  description = "IPs públicas de los NAT gateways. Estas son las direcciones de salida para entregar para lista blanca de IPs de terceros."
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
}

output "nat_gateway_mode" {
  description = "Modo de salida realmente aplicado. Devuelto para que módulos posteriores y revisiones de costos puedan afirmarlo."
  value       = var.nat_gateway_mode
}

###############################################################################
# VPC endpoints
###############################################################################

output "s3_vpc_endpoint_id" {
  description = "ID del endpoint de gateway de S3, o null cuando está deshabilitado."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "dynamodb_vpc_endpoint_id" {
  description = "ID del endpoint de gateway de DynamoDB, o null cuando está deshabilitado."
  value       = try(aws_vpc_endpoint.dynamodb[0].id, null)
}

output "interface_vpc_endpoint_ids" {
  description = "Mapa de nombre corto de servicio a ID de endpoint de interfaz."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "vpc_endpoints_security_group_id" {
  description = "ID del grupo de seguridad que protege los endpoints de interfaz, o null cuando no se solicitaron endpoints de interfaz."
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}

###############################################################################
# Flow logs
###############################################################################

output "flow_log_id" {
  description = "ID del flow log de VPC, o null cuando está deshabilitado."
  value       = try(aws_flow_log.this[0].id, null)
}

output "flow_logs_cloudwatch_log_group_name" {
  description = "Nombre del grupo de logs de CloudWatch que recibe flow logs, o null cuando los logs van a S3 o están deshabilitados."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}

output "flow_logs_cloudwatch_log_group_arn" {
  description = "ARN del grupo de logs de CloudWatch que recibe flow logs, o null cuando los logs van a S3 o están deshabilitados."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].arn, null)
}
