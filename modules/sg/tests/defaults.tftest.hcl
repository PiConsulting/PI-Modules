###############################################################################
# Tests de contrato, plan-only. Sin credenciales, sin recursos, sin coste.
#
#   terraform test
#
# El modulo no tiene data sources, asi que mock_provider vacio basta.
###############################################################################

mock_provider "aws" {}

variables {
  name        = "test-dev-alb"
  environment = "dev"
  vpc_id      = "vpc-0123456789abcdef0"
  description = "Security group de prueba para el modulo"
}

###############################################################################
# Comportamiento por defecto
###############################################################################

run "egress_abierto_por_defecto" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.allow_all) == 1
    error_message = "Con allow_all_egress por defecto debe existir la regla de salida abierta."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.allow_all[0].ip_protocol == "-1"
    error_message = "La regla de salida abierta debe usar ip_protocol -1."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.this) == 0
    error_message = "No debe haber reglas de salida explicitas cuando el egress esta abierto."
  }
}

run "usa_name_prefix_no_name" {
  command = plan

  assert {
    condition     = aws_security_group.this.name_prefix == "test-dev-alb-"
    error_message = "El SG debe usar name_prefix. Con name fijo, create_before_destroy falla con InvalidGroupName.Duplicate al modificar."
  }
}

###############################################################################
# Aplanado del mapa de reglas
###############################################################################

run "una_regla_con_dos_cidrs_produce_dos_recursos" {
  command = plan

  variables {
    ingress_rules = {
      "https" = {
        description = "HTTPS desde dos redes corporativas"
        from_port   = 443
        to_port     = 443
        cidr_blocks = ["10.0.0.0/8", "192.168.0.0/16"]
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 2
    error_message = "Cada CIDR debe generar su propio recurso: el recurso de AWS admite un unico origen."
  }

  assert {
    condition = alltrue([
      contains(keys(aws_vpc_security_group_ingress_rule.this), "https-cidr-0"),
      contains(keys(aws_vpc_security_group_ingress_rule.this), "https-cidr-1"),
    ])
    error_message = "Las claves aplanadas deben ser <clave>-cidr-<indice>."
  }
}

run "cidr_y_security_group_en_la_misma_entrada" {
  command = plan

  variables {
    ingress_rules = {
      "mixta" = {
        description               = "Desde una red y desde un grupo"
        from_port                 = 8080
        to_port                   = 8080
        cidr_blocks               = ["10.0.0.0/8"]
        source_security_group_ids = ["sg-0123456789abcdef0"]
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 2
    error_message = "Una entrada con un CIDR y un SG debe producir dos recursos."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["mixta-cidr-0"].referenced_security_group_id == null
    error_message = "La regla por CIDR no debe llevar referenced_security_group_id."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["mixta-sg-0"].cidr_ipv4 == null
    error_message = "La regla por security group no debe llevar cidr_ipv4."
  }
}

run "mapa_vacio_no_crea_reglas" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 0
    error_message = "Sin ingress_rules no debe crearse ninguna regla de entrada."
  }
}

###############################################################################
# Egress restringido
###############################################################################

run "egress_cerrado_aplica_reglas_explicitas" {
  command = plan

  variables {
    allow_all_egress = false
    egress_rules = {
      "postgres" = {
        description = "Salida hacia la base de datos"
        from_port   = 5432
        to_port     = 5432
        cidr_blocks = ["10.0.128.0/20"]
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.allow_all) == 0
    error_message = "Con allow_all_egress en false no debe existir la regla de salida abierta."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.this) == 1
    error_message = "Las reglas de salida explicitas deben aplicarse cuando el egress esta cerrado."
  }
}

run "egress_rules_se_ignoran_si_el_egress_esta_abierto" {
  command = plan

  variables {
    allow_all_egress = true
    egress_rules = {
      "ignorada" = {
        description = "No debe crearse porque la salida ya esta abierta"
        from_port   = 5432
        to_port     = 5432
        cidr_blocks = ["10.0.128.0/20"]
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.this) == 0
    error_message = "Con la salida abierta, egress_rules se ignora: una regla que abre todo hace irrelevante cualquier restriccion."
  }
}

###############################################################################
# Validaciones que deben rechazar
###############################################################################

run "ssh_abierto_al_mundo_se_rechaza" {
  command = plan

  variables {
    ingress_rules = {
      "ssh" = {
        description = "SSH de administracion"
        from_port   = 22
        to_port     = 22
        cidr_blocks = ["0.0.0.0/0"]
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "rango_amplio_que_cubre_postgres_se_rechaza" {
  command = plan

  variables {
    ingress_rules = {
      "todo" = {
        description = "Abrir todo temporalmente para depurar"
        from_port   = 0
        to_port     = 65535
        cidr_blocks = ["0.0.0.0/0"]
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "ipv6_abierto_en_puerto_administrativo_se_rechaza" {
  command = plan

  variables {
    ingress_rules = {
      "rdp" = {
        description = "Escritorio remoto"
        from_port   = 3389
        to_port     = 3389
        cidr_blocks = ["::/0"]
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "regla_sin_descripcion_se_rechaza" {
  command = plan

  variables {
    ingress_rules = {
      "https" = {
        description = ""
        from_port   = 443
        to_port     = 443
        cidr_blocks = ["10.0.0.0/8"]
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "regla_sin_origen_se_rechaza" {
  command = plan

  variables {
    ingress_rules = {
      "huerfana" = {
        description = "Regla que no permite nada"
        from_port   = 443
        to_port     = 443
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "puertos_invertidos_se_rechazan" {
  command = plan

  variables {
    ingress_rules = {
      "invertida" = {
        description = "Rango de puertos al reves"
        from_port   = 8080
        to_port     = 80
        cidr_blocks = ["10.0.0.0/8"]
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "protocolo_invalido_se_rechaza" {
  command = plan

  variables {
    ingress_rules = {
      "todos" = {
        description = "Todos los protocolos"
        from_port   = 443
        to_port     = 443
        protocol    = "-1"
        cidr_blocks = ["10.0.0.0/8"]
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "descripcion_del_grupo_demasiado_corta_se_rechaza" {
  command = plan

  variables {
    description = "sg"
  }

  expect_failures = [var.description]
}

run "entorno_invalido_se_rechaza" {
  command = plan

  variables {
    environment = "qa2"
  }

  expect_failures = [var.environment]
}

run "vpc_id_con_formato_invalido_se_rechaza" {
  command = plan

  variables {
    vpc_id = "mi-vpc"
  }

  expect_failures = [var.vpc_id]
}

###############################################################################
# Casos legitimos que NO deben rechazarse
###############################################################################

run "puerto_administrativo_desde_cidr_acotado_se_permite" {
  command = plan

  variables {
    ingress_rules = {
      "postgres-desde-app" = {
        description = "Postgres desde la subred de aplicacion"
        from_port   = 5432
        to_port     = 5432
        cidr_blocks = ["10.0.64.0/20"]
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 1
    error_message = "La restriccion es sobre 0.0.0.0/0, no sobre el puerto: un CIDR acotado debe permitirse."
  }
}

run "https_abierto_al_mundo_se_permite" {
  command = plan

  variables {
    ingress_rules = {
      "https" = {
        description = "HTTPS publico"
        from_port   = 443
        to_port     = 443
        cidr_blocks = ["0.0.0.0/0"]
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 1
    error_message = "El 443 abierto al mundo es el caso normal de un ALB publico y debe permitirse."
  }
}