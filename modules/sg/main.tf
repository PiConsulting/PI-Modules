################################################################################
# Security Group
################################################################################
# name_prefix + create_before_destroy es OBLIGATORIO (no opcional):
#
# - Modificar un SG con ENIs adjuntas falla con DependencyViolation si Terraform
#   intenta destruir antes de crear.
#
# - create_before_destroy resuelve eso, pero hace que el SG viejo y nuevo
#   coexistan unos segundos. Como los nombres deben ser únicos en la VPC,
#   usar "name" fijo causa InvalidGroupName.Duplicate.
#
# - name_prefix genera nombres únicos (ej: "app-20240807...") permitiendo
#   el reemplazo sin conflicto.
#
# Este fallo solo aparece al MODIFICAR, no al crear. Resolverlo aquí protege
# a todos los consumidores del módulo.
################################################################################

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = var.description
  vpc_id      = var.vpc_id

  tags = merge(
    local.tags,
    { Name = var.name }
  )

  lifecycle {
    create_before_destroy = true
  }
}


################################################################################
# Reglas de Ingreso
################################################################################
# Un recurso por cada combinación (puerto + protocolo + origen):
# - aws_vpc_security_group_ingress_rule acepta un único origen, nunca listas.
# - El aplanado se hace en locals.tf (1 regla con 3 CIDRs = 3 recursos).
#
# create_before_destroy también aquí: cuando el SG padre se reemplaza, las
# reglas se reemplazan con él. Sin esto, pueden quedar apuntando a un SG
# inexistente o crear ventanas sin protección de red.
################################################################################

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules_flat

  security_group_id = aws_security_group.this.id
  description       = each.value.description

  from_port   = each.value.from_port
  to_port     = each.value.to_port
  ip_protocol = each.value.ip_protocol

  cidr_ipv4                    = each.value.cidr_ipv4
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(
    local.tags,
    { Name = "${var.name}-ingress-${each.key}" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Regla de Egreso: Permitir Todo
################################################################################
# Recurso aparte porque con ip_protocol = "-1", AWS exige que from_port y
# to_port NO se pasen. Meterlo en el for_each obligaría a que esos campos
# fueran opcionales en todo el aplanado, contaminando el modelo de datos.
#
# Controlado por var.allow_all_egress (count = 0 o 1).
################################################################################

resource "aws_vpc_security_group_egress_rule" "allow_all" {
  count = var.allow_all_egress ? 1 : 0

  security_group_id = aws_security_group.this.id
  description       = "salida sin restriccion"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = merge(
    local.tags,
    { Name = "${var.name}-egress-allow-all" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Reglas de Egreso Explícitas
################################################################################
# Mismo patrón que ingreso: un recurso por cada combinación (puerto + protocolo + destino).
# El aplanado está en local.egress_rules_flat.
# Solo se crean cuando el usuario las define (típicamente con allow_all_egress = false).
################################################################################

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = local.egress_rules_flat

  security_group_id = aws_security_group.this.id
  description       = each.value.description

  from_port   = each.value.from_port
  to_port     = each.value.to_port
  ip_protocol = each.value.ip_protocol

  cidr_ipv4                    = each.value.cidr_ipv4
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(
    local.tags,
    { Name = "${var.name}-egress-${each.key}" }
  )

  lifecycle {
    create_before_destroy = true
  }
}
