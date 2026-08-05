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
