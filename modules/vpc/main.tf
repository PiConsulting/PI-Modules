# Se utiliza únicamente para componer nombres de servicios de punto de enlace de VPC.
data "aws_region" "current" {}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = var.instance_tenancy
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(
    local.tags,
    var.vpc_tags,
    { Name = "${var.name}-vpc" }
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  for_each = toset(var.secondary_cidr_blocks)

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value
}

# Elimina todas las reglas del Security Group predeterminado.
# AWS crea todo con una regla de "permitir" todo
resource "aws_default_security_group" "this" {
  count = var.manage_default_security_group ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.tags,
    { Name = "${var.name}-default-do-not-use" }
  )
}
