###############################################################################
# Tests de contrato, plan-only. Sin credenciales reales, sin recursos, sin coste.
#
#   terraform test
#
# El bloque mas importante es el primero: NORMALIZACION. Ahi esta el bug que
# nos costo dos rondas de plan contra AWS, y son las seis formas validas en las
# que un documento de politica puede llegar. Si el modulo rechaza alguna, esta
# roto aunque todo lo demas pase.
#
# Las politicas se construyen con jsonencode y no con aws_iam_policy_document
# a proposito: el data source SIEMPRE emite Statement como lista y Action como
# lista, asi que con el no se pueden ejercitar los casos de objeto suelto ni de
# cadena, que son justo los que fallaban.
#
# NO se usa mock_provider. mock_provider sustituye TODOS los data sources del
# provider por valores generados automaticamente, incluido
# data.aws_iam_policy_document.assume_role: su .json quedaria relleno con un
# valor ficticio que no es JSON valido, y aws_iam_role.this lo rechazaria en su
# propia validacion ("assume_role_policy contains an invalid JSON policy: not
# a JSON object"). Como aws_iam_policy_document no llama a la API de AWS, es
# preferible dejar que se calcule DE VERDAD. Mismo criterio ya aplicado en
# kms/tests/defaults.tftest.hcl.
#
# Se usa entonces un provider "aws" real con credenciales dummy y las
# validaciones de red desactivadas (skip_*), mas override_data para
# aws_partition (no llama a la API, pero se fija igual por determinismo).
# No hace falta override_data para aws_caller_identity: este modulo no lo usa.
###############################################################################

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_partition.current
  values = {
    id         = "aws"
    partition  = "aws"
    dns_suffix = "amazonaws.com"
  }
}

variables {
  name             = "test-dev-app"
  environment      = "dev"
  description      = "Rol de prueba del modulo iam-role"
  trusted_services = ["ecs-tasks.amazonaws.com"]

  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/plataforma-boundary"
}

###############################################################################
# Normalizacion de politicas
#
# Ninguno de estos debe fallar. Cubren las combinaciones de:
#   Statement: objeto suelto | lista
#   Action:    cadena        | lista
#   Resource:  cadena        | lista
###############################################################################

run "statement_objeto_con_action_y_resource_string" {
  command = plan

  variables {
    inline_policies = {
      simple = jsonencode({
        Version = "2012-10-17"
        Statement = {
          Sid      = "LeerUnObjeto"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "arn:aws:s3:::mi-bucket/*"
        }
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "Un Statement como objeto suelto con Action y Resource como cadena debe aceptarse."
  }
}

run "statement_lista_de_dos_es_el_caso_que_rompia" {
  command = plan

  variables {
    inline_policies = {
      dos = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "Uno"
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:ListBucket"]
            Resource = ["arn:aws:s3:::mi-bucket", "arn:aws:s3:::mi-bucket/*"]
          },
          {
            Sid      = "Dos"
            Effect   = "Allow"
            Action   = "secretsmanager:GetSecretValue"
            Resource = "arn:aws:secretsmanager:us-east-1:111122223333:secret:app/*"
          },
        ]
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "Dos statements con formas mixtas de Action y Resource deben aceptarse. Este es el caso exacto que rompia la normalizacion con un condicional: las ramas producian tuplas de longitud distinta."
  }
}

run "varias_politicas_a_la_vez" {
  command = plan

  variables {
    inline_policies = {
      lectura = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "arn:aws:s3:::mi-bucket/*"
        }]
      })
      escritura = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:DeleteObject"]
          Resource = "arn:aws:s3:::mi-bucket/*"
        }]
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 2
    error_message = "Cada entrada del mapa debe producir su propia politica inline."
  }
}

run "statement_con_deny_y_condition" {
  command = plan

  variables {
    inline_policies = {
      mixta = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Deny"
            Action   = "s3:DeleteBucket"
            Resource = "*"
          },
          {
            Effect   = "Allow"
            Action   = "s3:GetObject"
            Resource = "arn:aws:s3:::mi-bucket/*"
            Condition = {
              StringEquals = {
                "aws:SourceVpce" = "vpce-0123456789abcdef0"
              }
            }
          },
        ]
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "Un Deny sobre Resource '*' es legitimo y no debe confundirse con un Allow amplio. Y un statement con Condition tiene una forma distinta a uno sin ella, que es lo que rompe tolist()."
  }
}

run "sin_politicas_inline" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.this) == 0
    error_message = "Un rol sin politicas inline es valido: puede llevar solo politicas gestionadas."
  }
}

###############################################################################
# Comportamiento por defecto
###############################################################################

run "defaults" {
  command = plan

  assert {
    condition     = aws_iam_role.this.max_session_duration == 3600
    error_message = "La duracion de sesion por defecto debe ser 1 hora, no el maximo que permite AWS."
  }

  assert {
    condition     = aws_iam_role.this.name == "test-dev-app"
    error_message = "El modulo usa name exacto, no name_prefix: los nombres de rol aparecen en politicas de confianza de otras cuentas."
  }

  assert {
    condition     = length(aws_iam_instance_profile.this) == 0
    error_message = "El instance profile no debe crearse salvo que se pida: solo lo necesitan EC2 y autoescalado."
  }
}

run "instance_profile_bajo_demanda" {
  command = plan

  variables {
    create_instance_profile = true
  }

  assert {
    condition     = length(aws_iam_instance_profile.this) == 1
    error_message = "create_instance_profile debe crear el instance profile."
  }
}

run "politicas_gestionadas" {
  command = plan

  variables {
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
      "arn:aws:iam::aws:policy/ReadOnlyAccess",
    ]
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.this) == 2
    error_message = "Cada ARN de managed_policy_arns debe producir un attachment."
  }
}

###############################################################################
# Preconditions: patrones de escalada que deben rechazarse
###############################################################################

run "wildcard_admin_se_rechaza" {
  command = plan

  variables {
    inline_policies = {
      peligrosa = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "AbrirTodoMientrasDepuro"
          Effect   = "Allow"
          Action   = "*"
          Resource = "*"
        }]
      })
    }
  }

  expect_failures = [aws_iam_role.this]
}

run "passrole_sin_acotar_se_rechaza" {
  command = plan

  variables {
    inline_policies = {
      escalada = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "PasarCualquierRol"
          Effect   = "Allow"
          Action   = "iam:PassRole"
          Resource = "*"
        }]
      })
    }
  }

  expect_failures = [aws_iam_role.this]
}

run "assumerole_sobre_todo_se_rechaza" {
  command = plan

  variables {
    inline_policies = {
      pivote = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "AsumirCualquiera"
          Effect   = "Allow"
          Action   = "sts:AssumeRole"
          Resource = "*"
        }]
      })
    }
  }

  expect_failures = [aws_iam_role.this]
}

###############################################################################
# Casos legitimos que NO deben rechazarse
#
# Tan importantes como los anteriores: una validacion demasiado agresiva
# bloquea a un consumidor con una politica correcta, y eso se descubre tarde y
# de mal humor.
###############################################################################

run "wildcard_de_servicio_sobre_recurso_acotado_se_permite" {
  command = plan

  variables {
    inline_policies = {
      bucket = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "TodoSobreUnBucket"
          Effect   = "Allow"
          Action   = "s3:*"
          Resource = "arn:aws:s3:::mi-bucket/*"
        }]
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "s3:* sobre un bucket concreto es legitimo: la restriccion es sobre Action '*' Y Resource '*' a la vez."
  }
}

run "passrole_con_resource_acotado_se_permite" {
  command = plan

  variables {
    inline_policies = {
      passrole = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "PasarSoloEsteRol"
          Effect   = "Allow"
          Action   = "iam:PassRole"
          Resource = "arn:aws:iam::111122223333:role/app-execution"
        }]
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "iam:PassRole acotado a un ARN concreto es el uso correcto y debe permitirse."
  }
}

run "passrole_amplio_con_condicion_se_permite" {
  command = plan

  variables {
    inline_policies = {
      passrole = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "PasarRolesSoloAEcs"
          Effect   = "Allow"
          Action   = "iam:PassRole"
          Resource = "*"
          Condition = {
            StringEquals = {
              "iam:PassedToService" = "ecs-tasks.amazonaws.com"
            }
          }
        }]
      })
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "PassRole amplio pero restringido por condicion es el patron que recomienda AWS y debe permitirse."
  }
}

###############################################################################
# Confianza
###############################################################################

run "cross_account_sin_external_id_se_rechaza" {
  command = plan

  variables {
    trusted_services    = []
    trusted_account_ids = ["111122223333"]
  }

  expect_failures = [var.external_id]
}

run "cross_account_con_external_id_corto_se_rechaza" {
  command = plan

  variables {
    trusted_services    = []
    trusted_account_ids = ["111122223333"]
    external_id         = "corto"
  }

  expect_failures = [var.external_id]
}

run "cross_account_con_external_id_valido_se_permite" {
  command = plan

  variables {
    trusted_services    = []
    trusted_account_ids = ["111122223333"]
    external_id         = "un-identificador-compartido-con-entropia"
  }

  assert {
    condition     = aws_iam_role.this.name == "test-dev-app"
    error_message = "Confianza cross-account con external_id valido debe aceptarse."
  }
}

run "sin_origen_de_confianza_se_rechaza" {
  command = plan

  variables {
    trusted_services    = []
    trusted_account_ids = []
  }

  expect_failures = [var.trusted_services]
}

run "principal_de_servicio_invalido_se_rechaza" {
  command = plan

  variables {
    trusted_services = ["ec2"]
  }

  expect_failures = [var.trusted_services]
}

run "cuenta_con_formato_invalido_se_rechaza" {
  command = plan

  variables {
    trusted_services    = []
    trusted_account_ids = ["12345"]
    external_id         = "un-identificador-compartido-con-entropia"
  }

  expect_failures = [var.trusted_account_ids]
}

###############################################################################
# Limite de permisos
###############################################################################

run "sin_boundary_y_sin_justificacion_se_rechaza" {
  command = plan

  variables {
    permissions_boundary_arn = null
  }

  expect_failures = [var.boundary_exempt_reason]
}

run "sin_boundary_con_justificacion_corta_se_rechaza" {
  command = plan

  variables {
    permissions_boundary_arn = null
    boundary_exempt_reason   = "no hace falta"
  }

  expect_failures = [var.boundary_exempt_reason]
}

run "sin_boundary_con_justificacion_valida_se_permite" {
  command = plan

  variables {
    permissions_boundary_arn = null
    boundary_exempt_reason   = "Rol de solo lectura sin permisos de IAM; el cliente aun no tiene politica de boundary desplegada"
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "Con la exencion documentada, el rol se crea sin boundary."
  }
}

###############################################################################
# Validaciones basicas
###############################################################################

run "nombre_con_mayusculas_se_rechaza" {
  command = plan

  variables {
    name = "Test-Dev-App"
  }

  expect_failures = [var.name]
}

run "entorno_invalido_se_rechaza" {
  command = plan

  variables {
    environment = "qa2"
  }

  expect_failures = [var.environment]
}

run "descripcion_corta_se_rechaza" {
  command = plan

  variables {
    description = "rol"
  }

  expect_failures = [var.description]
}

run "sesion_de_mas_de_doce_horas_se_rechaza" {
  command = plan

  variables {
    max_session_duration = 86400
  }

  expect_failures = [var.max_session_duration]
}

run "json_invalido_se_rechaza" {
  command = plan

  variables {
    inline_policies = {
      rota = "{ esto no es json"
    }
  }

  expect_failures = [var.inline_policies]
}