# Se utiliza únicamente para componer nombres de servicios de punto de enlace de VPC.
# NOTA: `.name` es válido en las versiones 5.x y 6.x del proveedor, pero la versión 6.x lo marca como obsoleto
# en favor de `.region`. Realice el cambio cuando la versión mínima del proveedor pase a ser >= 6.0.

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

###############################################################################
# Internet gateway
###############################################################################

resource "aws_internet_gateway" "this" {
  count = var.create_public_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.tags,
    { Name = "${var.name}-igw" }
  )
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(
    local.tags,
    var.public_subnet_tags,
    {
      Name = "${var.name}-public-${each.key}"
      Tier = "public"
    }
  )
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = false

  tags = merge(
    local.tags,
    var.private_subnet_tags,
    {
      Name = "${var.name}-private-${each.key}"
      Tier = "private"
    }
  )
}

resource "aws_subnet" "database" {
  for_each = local.database_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = false

  tags = merge(
    local.tags,
    var.database_subnet_tags,
    {
      Name = "${var.name}-database-${each.key}"
      Tier = "database"
    }
  )
}

resource "aws_db_subnet_group" "this" {
  count = var.create_database_subnets && var.create_database_subnet_group ? 1 : 0

  name        = "${var.name}-db"
  description = "Database subnet group for ${var.name}"
  subnet_ids  = [for k in local.database_subnet_keys : aws_subnet.database[k].id]

  tags = merge(
    local.tags,
    { Name = "${var.name}-db" }
  )
}

###############################################################################
# NAT gateways
###############################################################################

resource "aws_eip" "nat" {
  for_each = local.nat_gateways
  domain   = "vpc"

  tags = merge(
    local.tags,
    { Name = "${var.name}-nat-${each.key}" }
  )

  lifecycle {
    precondition {
      condition     = var.create_public_subnets
      error_message = "nate_gateway_mode requiere create_public_subnets = true, ya que un NAT GTW debe desplegarse en una subnet publica"
    }
  }
}

resource "aws_nat_gateway" "this" {
  for_each = local.nat_gateways

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(
    local.tags,
    { Name = "${var.name}-nat-${each.key}" }
  )

  # El IGW debe existir y estar asociado antes de poder crear un NAT Gateway.
  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Route tables - public
###############################################################################

resource "aws_route_table" "public" {
  count = var.create_public_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.tags,
    { Name = "${var.name}-rt-public" }
  )
}

resource "aws_route" "public_internet" {
  count = var.create_public_subnets ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

###############################################################################
# Route tables - private
###############################################################################

resource "aws_route_table" "private" {
  for_each = toset(local.private_rt_keys)

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.tags,
    { Name = "${var.name}-rt-private-${each.key}" }
  )
}

resource "aws_route" "private_nat" {
  for_each = local.private_rt_nat_az

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id

  timeouts {
    create = "5m"
  }
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[local.private_rt_for_az[each.key]].id
}

###############################################################################
# Route tables - database - aislado por defecto
###############################################################################

resource "aws_route_table" "database" {
  count = var.create_database_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.tags,
    { Name = "${var.name}-rt-database" }
  )
}

resource "aws_route" "database_nat" {
  count = var.create_database_subnets && var.database_subnets_route_to_nat && var.nat_gateway_mode != "none" ? 1 : 0

  route_table_id         = aws_route_table.database[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_azs[0]].id
}

resource "aws_route_table_association" "database" {
  for_each = local.database_subnets

  subnet_id      = aws_subnet.database[each.key].id
  route_table_id = aws_route_table.database[0].id
}

###############################################################################
# Gateway VPC endpoints - Gratis
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
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
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
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
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for k in local.private_subnet_keys : aws_subnet.private[k].id]
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = var.interface_endpoints_private_dns_enabled

  tags = merge(
    local.tags,
    { Name = "${var.name}-vpce-${replace(each.value, ".", "-")}" }
  )
}

###############################################################################
# Flow logs
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn

  tags = merge(
    local.tags,
    { Name = "${var.name}-flow-logs" }
  )
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogsStream",
      "logs:PutLogEvents",
      "logs:DescribeLogsStreams"
    ]

    # Restringe el acceso únicamente a este grupo de registros, evitando el uso de comodines (*)
    resources = [aws_cloudwatch_log_group.flow_logs[0].arn, "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  description        = "Permite a los VPC Flow Logs enviar registros al Log Group de CloudWatch Logs para ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  name   = "${var.name}-vpc-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_logs_traffic_type
  max_aggregation_interval = var.flow_logs_max_aggregation_interval

  log_destination_type = var.flow_logs_destination_type
  log_destination      = local.flow_logs_to_cloudwatch ? aws_cloudwatch_log_group.flow_logs[0].arn : var.flow_logs_s3_destination_arn
  iam_role_arn         = local.flow_logs_to_cloudwatch ? aws_iam_role.flow_logs[0].arn : null

  tags = merge(
    local.tags,
    { Name = "${var.name}-flow-logs" }
  )

  lifecycle {
    precondition {
      condition     = !local.flow_logs_to_s3 || var.flow_logs_s3_destination_arn != null
      error_message = "Debe especificarse flow_logs_s3_destination_arn cuando flow_logs_destination_type es 's3'"
    }
  }
}
