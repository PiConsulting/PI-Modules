###############################################################################
# Gateway VPC endpoints - Gratis
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_table_ids

  tags = merge(
    local.tags,
    { Name = "${var.name}-vpce-s3" }
  )
}

resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_dynamodb_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_table_ids

  tags = merge(
    local.tags,
    { Name = "${var.name}-vpce-dynamodb" }
  )
}

###############################################################################
# Interface VPC endpoints
###############################################################################

resource "aws_security_group" "vpc_endpoints" {
  count = local.create_interface_endpoints ? 1 : 0

  name        = "${var.name}-vpce"
  description = "Permitir HTTPS desde la VPC hacia los puntos de enlace de VPC de la interfaz"
  vpc_id      = aws_vpc.this.id

  tags = merge(
    local.tags,
    { Name = "${var.name}-vpce" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  for_each = local.create_interface_endpoints ? toset(local.interface_endpoint_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS desde ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = local.tags
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for k in local.private_subnet_keys : aws_subnet.private[k].id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.interface_endpoints_private_dns_enabled

  tags = merge(
    local.tags,
    { Name = "${var.name}-vpce-${replace(each.value, ".", "-")}" }
  )
}
