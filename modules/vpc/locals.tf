locals {
  azs      = var.availability_zones
  az_count = length(local.azs)


  #####################################
  # Tags
  #####################################
  # Etiquetas base aplicadas a todos los recursos. Las etiquetas internas del módulo son obligatorias y tienen prioridad absoluta sobre las del llamador para garantizar el contrato de trazabilidad y gobernanza.
  tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "vpc"
    }
  )

  ########################################################################
  # calculo de CIDR para Subredes
  #
  # cada capa (tier) tiene asignado un bloque reservado de slots. De este modo,
  # el añadir una nueva AZ en el futuro, se anexa la nueva subred al final
  # en lugar de reindexar y cambiar la numeracion de las subredes existentes
  #
  # Ejemplo con subnet_newbits - 4 y subnet_slots_per_tier - 4 en un bloque /16:
  #   public   -> slots 0..3   (10.0.0.0/20  ... 10.0.48.0/20)
  #   private  -> slots 4..7   (10.0.64.0/20 ... 10.0.112.0/20)
  #   database -> slots 8..11  (10.0.128.0/20 ...)
  #   free     -> slots 12..15 (bloques reservados para futuras capas)
  ##########################################################################

  auto_public_cidrs = [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
  ]

  auto_private_cidrs = [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + var.subnet_slots_per_tier)
  ]

  auto_database_cidrs = [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + (2 * var.subnet_slots_per_tier))
  ]

  public_cidrs   = length(var.public_subnet_cidrs) > 0 ? var.public_subnet_cidrs : local.auto_public_cidrs
  private_cidrs  = length(var.private_subnet_cidrs) > 0 ? var.private_subnet_cidrs : local.auto_private_cidrs
  database_cidrs = length(var.database_subnet_cidrs) > 0 ? var.database_subnet_cidrs : local.auto_database_cidrs

  ###########################################################################
  # Mapas de subnets
  #
  # Se utilizan las AZ como clave para mantener identificadores estables en
  # for_each. De esta forma, eliminar una AZ solo afecta a su subnet y no a
  # las del resto de las zonas.
  ###########################################################################

  public_subnets = var.create_public_subnets ? {
    for idx, az in local.azs : az => {
      cidr_block = local.public_cidrs[idx]
      index      = idx
    }
  } : {}

  private_subnets = {
    for idx, az in local.azs : az => {
      cidr_block = local.private_cidrs[idx]
      index      = idx
    }
  }

  database_subnets = var.create_database_subnets ? {
    for idx, az in local.azs : az => {
      cidr_block = local.database_cidrs[idx]
      index      = idx
    }
  } : {}


  # Mantiene una lista ordenada de claves para garantizar que los outputs
  # conserven el mismo orden que availability_zones.
  public_subnet_keys   = var.create_public_subnets ? local.azs : []
  private_subnet_keys  = local.azs
  database_subnet_keys = var.create_database_subnets ? local.azs : []

  ###########################################################################
  # NAT gateways
  ###########################################################################

  nat_azs = var.nat_gateway_mode == "none" ? [] : (
    var.nat_gateway_mode == "single" ? slice(local.azs, 0, 1) : local.azs
  )

  nat_gateways = { for az in local.nat_azs : az => az }



  ###########################################################################
  # Private route tables
  #
  # one_per_az -> Crea una tabla de rutas para cada AZ, donde cada una utiliza
  #               su Nat Gateway local. Esto evita que la caida de una AZ o de
  #               un Nat Gateway afecte a toda la VPC
  #
  # single/none -> utiliza una unica tabla de rutas compartida
  ###########################################################################

  private_rt_for_az = {
    for az in local.azs : az => (var.nat_gateway_mode == "one_per_az" ? az : "shared")
  }

  private_rt_keys = distinct(values(local.private_rt_for_az))

  # Relación entre cada tabla de rutas y la AZ del NAT Gateway que utilizará
  private_rt_nat_az = var.nat_gateway_mode == "none" ? {} : {
    for k in local.private_rt_keys : k => (k == "shared" ? local.nat_azs[0] : k)
  }

  ###########################################################################
  # VPC endpoints
  ###########################################################################

  all_vpc_cidrs = concat([var.vpc_cidr], var.secondary_cidr_blocks)

  interface_endpoint_ingress_cidrs = length(var.interface_endpoints_allowed_cidrs) > 0 ? var.interface_endpoints_allowed_cidrs : local.all_vpc_cidrs

  interface_endpoints = { for svc in var.interface_endpoint_services : svc => svc }

  create_interface_endpoints = length(var.interface_endpoint_services) > 0

  # Los Gateway Endpoints se asocian a route tables, no a subnets
  gateway_endpoint_route_table_ids = concat(
    [for k in local.private_rt_keys : aws_route_table.private[k].id],
    var.create_public_subnets ? [aws_route_table.public[0].id] : [],
    var.create_database_subnets ? [aws_route_table.database[0].id] : []
  )

  ###########################################################################
  # Flow logs
  ###########################################################################

  flow_logs_to_cloudwatch = var.enable_flow_logs && var.flow_logs_destination_type == "cloud-watch-logs"
  flow_logs_to_s3         = var.enable_flow_logs && var.flow_logs_destination_type == "s3"
  flow_logs_retention_by_environment = {
    dev  = 30
    stg  = 90
    prod = 365
  }
  flow_logs_retention_days = var.flow_logs_retention_days != null ? var.flow_logs_retention_days : local.flow_logs_retention_by_environment[var.environment]

}

