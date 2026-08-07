locals {
  tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "sg"
    }
  )

  ###########################################################################
  # reglas
  #
  # aws_vpc_security_group_ingress_rule admite UN solo origen por recurso: o
  # un cidr_ipv4, o un referenced_security_group_id. Nunca listas.
  #
  # Por eso cada entrada del mapa de entrada se expande a N + M recursos:
  # uno por CIDR y uno por security group de origen.
  #
  # Ambos origenes se normalizan a la MISMA forma de objeto, con null en el
  # campo que no aplica, para poder usar un unico recurso con for_each en vez
  # de dos recursos distintos. Menos direcciones en el state y un diff mas
  # legible.
  #
  # Se usa flatten + comprension en lugar de merge(...) con spread porque
  # maneja el mapa vacio de forma natural: flatten([]) es [], y la comprension
  # sobre [] es {}. Con merge(...)... haria falta prepender un {} para que la
  # llamada nunca quede sin argumentos.
  #
  # LIMITACION ACEPTADA: el indice de la clave sale de la posicion en la
  # lista, asi que reordenar cidr_blocks recrea esas reglas. Es barato -una
  # regla se recrea en segundos y no hay perdida de datos- y la alternativa
  # (derivar la clave del valor) rompe el caso de los IDs desconocidos en
  # plan, que es precisamente lo que este diseno resuelve.
  ###########################################################################

  ingress_rules_flat = {
    for item in flatten([
      for key, rule in var.ingress_rules : concat(
        [
          for idx, cidr in rule.cidr_blocks : {
            key                          = "${key}-cidr-${idx}"
            description                  = rule.description
            from_port                    = rule.from_port
            to_port                      = rule.to_port
            ip_protocol                  = rule.protocol
            cidr_ipv4                    = cidr
            referenced_security_group_id = null
          }
        ],
        [
          for idx, sg_id in rule.source_security_group_ids : {
            key                          = "${key}-sg-${idx}"
            description                  = rule.description
            from_port                    = rule.from_port
            to_port                      = rule.to_port
            ip_protocol                  = rule.protocol
            cidr_ipv4                    = null
            referenced_security_group_id = sg_id
          }
        ]
      )
    ]) : item.key => item
  }

  # Las reglas de salida explicitas solo existen cuando el egress no esta
  # abierto. Si allow_all_egress es true, cualquier egress_rules que se pase
  # se ignora en silencio -documentado en el README- porque una regla que
  # abre todo hace irrelevante cualquier restriccion posterior.

  egress_rules_flat = var.allow_all_egress ? {} : {
    for item in flatten([
      for key, rule in var.egress_rules : concat(
        [
          for idx, cidr in rule.cidr_blocks : {
            key                          = "${key}-cidr-${idx}"
            description                  = rule.description
            from_port                    = rule.from_port
            to_port                      = rule.to_port
            ip_protocol                  = rule.protocol
            cidr_ipv4                    = cidr
            referenced_security_group_id = null
          }
        ],
        [
          for idx, sg in rule.source_security_group_ids : {
            key                          = "${key}-sg-${idx}"
            description                  = rule.description
            from_port                    = rule.from_port
            to_port                      = rule.to_port
            ip_protocol                  = rule.protocol
            cidr_ipv4                    = null
            referenced_security_group_id = sg
          }
        ]
      )
    ]) : item.key => item
  }
}

