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
