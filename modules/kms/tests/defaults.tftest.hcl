###############################################################################
# Tests de contrato, plan-only. Sin credenciales reales, sin recursos, sin coste.
#
#   terraform test
#
# NO se usa mock_provider. mock_provider sustituye TODOS los data sources del
# provider por valores generados automaticamente, incluido
# data.aws_iam_policy_document.key: su .json quedaria relleno con un valor
# ficticio que no es JSON valido, y aws_kms_key.this lo rechazaria en su propia
# validacion (asi fallaba antes: "policy contains an invalid JSON"). Como
# aws_iam_policy_document no llama a la API de AWS, es preferible dejar que se
# calcule DE VERDAD: es la unica forma de que jsondecode(aws_kms_key.this.policy)
# refleje la politica real generada por locals.tf, en vez de solo contar
# statements.
#
# Se usa entonces un provider "aws" real con credenciales dummy y las
# validaciones de red desactivadas (skip_*), mas override_data para los dos
# data sources que si necesitarian una llamada real (aws_partition normalmente
# no llama a la API, pero se fija igual por determinismo; aws_caller_identity
# hace sts:GetCallerIdentity y se debe reemplazar). local.account_id participa
# en local.root_arn y en la precondition 4 (control externo): sin una cuenta
# fija el test no podria distinguir "mismo account" de "cuenta externa".
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

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111122223333"
    arn        = "arn:aws:iam::111122223333:user/test"
    id         = "111122223333"
    user_id    = "AIDAEXAMPLE"
  }
}

variables {
  name        = "test-dev-app"
  environment = "dev"
  description = "Clave de prueba del modulo kms"
}

###############################################################################
# Comportamiento por defecto
###############################################################################

run "defaults" {
  command = plan

  assert {
    condition     = aws_kms_key.this.deletion_window_in_days == 30
    error_message = "El deletion_window_in_days por defecto debe ser el maximo (30): mejor recuperacion ante error."
  }

  assert {
    condition     = aws_kms_key.this.rotation_period_in_days == 365
    error_message = "El rotation_period_in_days por defecto debe ser 365."
  }

  assert {
    condition     = aws_kms_key.this.is_enabled == true
    error_message = "La clave debe estar habilitada por defecto."
  }

  assert {
    condition     = aws_kms_key.this.multi_region == false
    error_message = "La clave no debe ser multiregion por defecto."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true
    error_message = "La rotacion automatica debe estar siempre activa, sin variable que la desactive."
  }

  assert {
    condition     = aws_kms_key.this.bypass_policy_lockout_safety_check == false
    error_message = "bypass_policy_lockout_safety_check debe ser siempre false: es la proteccion anti-lockout."
  }

  assert {
    condition     = aws_kms_alias.this.name == "alias/dev/test-dev-app"
    error_message = "El alias principal debe seguir el patron alias/<entorno>/<nombre>."
  }

  assert {
    condition     = aws_kms_key.this.tags["Name"] == "dev-test-dev-app-kms"
    error_message = "El tag Name debe seguir el patron <entorno>-<nombre>-kms."
  }

  assert {
    condition = (
      length(jsondecode(aws_kms_key.this.policy).Statement) == 1
      && jsondecode(aws_kms_key.this.policy).Statement[0].Sid == "EnableIAMUserPermissions"
    )
    error_message = "Sin key_administrators, key_users ni service_principals, la policy debe tener solo el statement raiz."
  }

  assert {
    condition     = length(aws_kms_alias.additional) == 0
    error_message = "Sin additional_aliases no debe crearse ningun alias secundario."
  }
}

###############################################################################
# Statements generados por rol
###############################################################################

run "key_administrators_genera_statement_de_administracion_sin_cripto" {
  command = plan

  variables {
    key_administrators = ["arn:aws:iam::111122223333:role/kms-admin"]
  }

  assert {
    condition     = length(jsondecode(aws_kms_key.this.policy).Statement) == 2
    error_message = "Con key_administrators debe aparecer el statement raiz mas el de administracion."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.this.policy).Statement :
      !contains(s.Action, "kms:CreateGrant") && !contains(s.Action, "kms:Decrypt")
      if s.Sid == "KeyAdministration"
    ])
    error_message = "El statement de administracion NO debe incluir kms:CreateGrant ni kms:Decrypt: un administrador no debe poder auto-concederse lectura del dato cifrado."
  }
}

run "key_users_genera_statement_cripto_y_statement_de_grants" {
  command = plan

  variables {
    key_users = ["arn:aws:iam::111122223333:role/app-runtime"]
  }

  assert {
    condition     = length(jsondecode(aws_kms_key.this.policy).Statement) == 3
    error_message = "Con key_users debe aparecer el statement raiz, el de uso criptografico y el de grants."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.this.policy).Statement :
      contains(s.Action, "kms:Decrypt") && contains(s.Action, "kms:Encrypt")
      if s.Sid == "KeyUsageCryptographic"
    ])
    error_message = "El statement de uso criptografico debe conceder Decrypt y Encrypt."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.this.policy).Statement :
      contains(s.Action, "kms:CreateGrant")
      && s.Condition.Bool["kms:GrantIsForAWSResource"] == "true"
      if s.Sid == "KeyUsageGrants"
    ])
    error_message = "El statement de grants debe existir y acotar kms:CreateGrant con la condicion kms:GrantIsForAWSResource=true. Sin esto, ASG/RDS/Lambda no pueden lanzar recursos cifrados con esta clave."
  }
}

run "service_principal_usa_acciones_por_defecto_y_sid_derivado" {
  command = plan

  variables {
    service_principals = {
      "logs.us-east-1.amazonaws.com" = {}
    }
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.this.policy).Statement :
      contains(s.Action, "kms:Decrypt")
      && contains(s.Action, "kms:GenerateDataKey*")
      if s.Sid == "ServiceUsageLogsUsEast1"
    ])
    error_message = "El Sid se deriva del principal (logs.us-east-1.amazonaws.com -> ServiceUsageLogsUsEast1) y las acciones por defecto deben aplicarse cuando no se especifican."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.this.policy).Statement :
      s.Condition.StringEquals["aws:SourceAccount"] == "111122223333"
      if s.Sid == "ServiceUsageLogsUsEast1"
    ])
    error_message = "aws:SourceAccount debe inyectarse siempre, sin variable que lo desactive: cierra el vector confused-deputy."
  }

  assert {
    condition = (
      length(output.unscoped_service_principals) == 1
      && contains(output.unscoped_service_principals, "logs.us-east-1.amazonaws.com")
    )
    error_message = "Un service principal solo con la condicion minima (aws:SourceAccount) debe listarse en unscoped_service_principals para auditoria."
  }
}

run "service_principal_acotado_no_aparece_como_unscoped" {
  command = plan

  variables {
    service_principals = {
      "s3.amazonaws.com" = {
        source_arns = ["arn:aws:s3:::acme-prod-data"]
      }
    }
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.this.policy).Statement :
      s.Condition.ArnLike["aws:SourceArn"] == "arn:aws:s3:::acme-prod-data"
      if s.Sid == "ServiceUsageS3"
    ])
    error_message = "source_arns debe traducirse en una condicion ArnLike sobre aws:SourceArn."
  }

  assert {
    condition     = length(output.unscoped_service_principals) == 0
    error_message = "Un service principal con source_arns ya no esta 'sin acotar' y no debe aparecer en unscoped_service_principals."
  }
}

###############################################################################
# Alias adicionales
###############################################################################

run "additional_aliases_crea_un_alias_por_entrada" {
  command = plan

  variables {
    additional_aliases = ["legacy-name"]
  }

  assert {
    condition     = length(aws_kms_alias.additional) == 1
    error_message = "Cada entrada de additional_aliases debe crear un aws_kms_alias.additional."
  }

  assert {
    condition     = aws_kms_alias.additional["legacy-name"].name == "alias/dev/legacy-name"
    error_message = "El alias adicional debe seguir el mismo patron alias/<entorno>/<nombre> que el principal."
  }
}

###############################################################################
# Preconditions: patrones de lockout y exposicion que deben rechazarse
#
# expect_failures apunta al recurso (aws_kms_key.this), no a una variable:
# son lifecycle.precondition, igual que en iam-role.
###############################################################################

run "extra_policy_reutiliza_sid_reservado_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::111122223333:role/otro" }
        Action    = "kms:Decrypt"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_kms_key.this]
}

run "extra_policy_deny_con_notprincipal_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid          = "DenyExceptSome"
        Effect       = "Deny"
        NotPrincipal = { AWS = "arn:aws:iam::111122223333:role/allowed" }
        Action       = "kms:*"
        Resource     = "*"
      }]
    })
  }

  expect_failures = [aws_kms_key.this]
}

run "extra_policy_wildcard_sin_condition_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "OpenToEveryone"
        Effect    = "Allow"
        Principal = "*"
        Action    = "kms:Decrypt"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_kms_key.this]
}

# has_condition (locals.tf) se calculaba con can(s.Condition), que solo mira si
# la CLAVE existe. Un objeto Condition presente pero vacio pasaba como "tiene
# condicion" sin restringir nada de verdad. Este caso verifica que ahora se
# exige al menos un operador real dentro de Condition.
run "extra_policy_wildcard_con_condition_vacia_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "OpenToEveryoneEmptyCondition"
        Effect    = "Allow"
        Principal = "*"
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = {}
      }]
    })
  }

  expect_failures = [aws_kms_key.this]
}

run "extra_policy_putkeypolicy_a_cuenta_externa_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "ExternalAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::444455556666:root" }
        Action    = "kms:PutKeyPolicy"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_kms_key.this]
}

run "extra_policy_kms_wildcard_a_cuenta_externa_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "ExternalFullControl"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::444455556666:role/external" }
        Action    = "kms:*"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_kms_key.this]
}

###############################################################################
# service_principals con Sid derivado colisionante — SIN test automatizado
#
# service_sids no es inyectivo: "logs.us-east-1.amazonaws.com" y
# "logs-us-east-1.amazonaws.com" normalizan al mismo Sid
# "ServiceUsageLogsUsEast1". La proteccion es real: el proveedor de AWS
# rechaza el plan con su propio error ("duplicate Sid ... Remove the Sid or
# ensure the Sid is unique") porque ambos statements se declaran en el mismo
# dynamic "statement" de data.aws_iam_policy_document.key.
#
# No se puede expresar como run con expect_failures: ese mecanismo solo
# reconoce fallos de bloques precondition/postcondition/validation del propio
# modulo, no errores nativos del proveedor durante la construccion del data
# source. Un run con expect_failures = [data.aws_iam_policy_document.key]
# falla igual, con "was expected to report an error but did not", aunque el
# plan SI falla y el error SI señala ese objeto. Verificado manualmente con
# `terraform plan` usando esta misma combinacion de service_principals.
###############################################################################
# Casos legitimos con extra_policy_json que NO deben rechazarse
#
# Tan importantes como los anteriores: una precondition demasiado agresiva
# bloquea un cross-account correcto, y eso se descubre tarde.
###############################################################################

run "extra_policy_cross_account_acotado_con_condition_se_permite" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "AllowCrossAccountUse"
        Effect    = "Allow"
        Principal = { AWS = ["arn:aws:iam::444455556666:role/external-consumer"] }
        Action    = ["kms:Decrypt", "kms:Encrypt"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.us-east-1.amazonaws.com" }
        }
      }]
    })
  }

  assert {
    condition     = output.has_policy_override == true
    error_message = "Un cross-account con acciones criptograficas acotadas y Condition es el caso real que extra_policy_json existe para permitir."
  }
}

run "extra_policy_wildcard_con_condition_de_org_se_permite" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "OrgWideAccess"
        Effect    = "Allow"
        Principal = "*"
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = "o-example123456" }
        }
      }]
    })
  }

  assert {
    condition     = output.has_policy_override == true
    error_message = "Principal comodin ACOTADO por una Condition (aws:PrincipalOrgID) es un patron valido y no debe confundirse con un comodin desnudo."
  }
}

run "extra_policy_putkeypolicy_dentro_de_la_misma_cuenta_se_permite" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "InternalEmergencyAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::111122223333:role/kms-emergency-admin" }
        Action    = "kms:PutKeyPolicy"
        Resource  = "*"
      }]
    })
  }

  assert {
    condition     = output.has_policy_override == true
    error_message = "kms:PutKeyPolicy concedido a un principal de la MISMA cuenta no cede control a un tercero y debe permitirse."
  }
}

# NOTA: un Statement como objeto SUELTO (sin envolver en lista) NO se prueba
# aqui como caso aceptado. local.custom_statements (locals.tf) lo normaliza
# con flatten() para las preconditions de seguridad, pero ese JSON crudo
# tambien se pasa TAL CUAL a source_policy_documents (main.tf linea 23), y el
# merge interno del provider AWS exige que Statement sea siempre un array:
# con un objeto suelto, el plan falla con un error de Go sin relacion con las
# preconditions ("cannot unmarshal object into ... []*iam.iamPolicyStatement"),
# antes de que la validacion de seguridad del modulo llegue a evaluarse. La
# descripcion de extra_policy_json ya recomienda construirlo con
# data.aws_iam_policy_document, que SIEMPRE emite Statement como lista, asi
# que el caso no deberia darse en uso normal — pero si alguien escribe el JSON
# a mano, el error que recibe no es el que el modulo fue diseñado para dar.
run "extra_policy_statement_con_action_y_principal_como_string_se_acepta" {
  command = plan

  variables {
    extra_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "SingleObjectStatement"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::111122223333:role/otro" }
        Action    = "kms:DescribeKey"
        Resource  = "*"
      }]
    })
  }

  assert {
    condition     = output.has_policy_override == true
    error_message = "Statement en una lista de un elemento, con Action y Principal.AWS como cadena (formas escalares validas de un documento IAM), debe normalizarse y aceptarse."
  }
}

###############################################################################
# extra_policy_json — validaciones basicas
###############################################################################

run "extra_policy_json_invalido_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = "{ esto no es json"
  }

  expect_failures = [var.extra_policy_json]
}

run "extra_policy_json_sin_statement_se_rechaza" {
  command = plan

  variables {
    extra_policy_json = jsonencode({ Version = "2012-10-17" })
  }

  expect_failures = [var.extra_policy_json]
}

###############################################################################
# Validaciones basicas de variables
###############################################################################

run "nombre_con_formato_invalido_se_rechaza" {
  command = plan

  variables {
    name = "ab"
  }

  expect_failures = [var.name]
}

run "nombre_con_prefijo_aws_se_rechaza" {
  command = plan

  variables {
    name = "aws/mi-clave"
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
    description = "clave"
  }

  expect_failures = [var.description]
}

run "descripcion_demasiado_larga_se_rechaza" {
  command = plan

  variables {
    description = join("", [for i in range(820) : "aaaaaaaaaa"])
  }

  expect_failures = [var.description]
}

run "deletion_window_por_debajo_del_minimo_se_rechaza" {
  command = plan

  variables {
    deletion_window_in_days = 5
  }

  expect_failures = [var.deletion_window_in_days]
}

run "deletion_window_por_encima_del_maximo_se_rechaza" {
  command = plan

  variables {
    deletion_window_in_days = 31
  }

  expect_failures = [var.deletion_window_in_days]
}

run "deletion_window_no_entero_se_rechaza" {
  command = plan

  variables {
    deletion_window_in_days = 15.5
  }

  expect_failures = [var.deletion_window_in_days]
}

run "rotation_period_por_debajo_del_minimo_se_rechaza" {
  command = plan

  variables {
    rotation_period_in_days = 60
  }

  expect_failures = [var.rotation_period_in_days]
}

run "rotation_period_por_encima_del_maximo_se_rechaza" {
  command = plan

  variables {
    rotation_period_in_days = 3000
  }

  expect_failures = [var.rotation_period_in_days]
}

run "rotation_period_no_entero_se_rechaza" {
  command = plan

  variables {
    rotation_period_in_days = 100.5
  }

  expect_failures = [var.rotation_period_in_days]
}

run "alias_adicional_con_prefijo_alias_se_rechaza" {
  command = plan

  variables {
    additional_aliases = ["alias/dev/legacy"]
  }

  expect_failures = [var.additional_aliases]
}

run "alias_adicional_con_formato_invalido_se_rechaza" {
  command = plan

  variables {
    additional_aliases = ["x"]
  }

  expect_failures = [var.additional_aliases]
}

run "alias_adicional_con_prefijo_aws_se_rechaza" {
  command = plan

  variables {
    additional_aliases = ["aws/legacy"]
  }

  expect_failures = [var.additional_aliases]
}

run "alias_adicional_igual_a_name_se_rechaza" {
  command = plan

  variables {
    additional_aliases = ["test-dev-app"]
  }

  expect_failures = [var.additional_aliases]
}

run "key_administrators_con_arn_invalido_se_rechaza" {
  command = plan

  variables {
    key_administrators = ["arn:aws:iam::12345:role/x"]
  }

  expect_failures = [var.key_administrators]
}

run "key_users_con_arn_invalido_se_rechaza" {
  command = plan

  variables {
    key_users = ["no-es-un-arn"]
  }

  expect_failures = [var.key_users]
}

run "service_principal_con_clave_invalida_se_rechaza" {
  command = plan

  variables {
    service_principals = {
      "logs" = {}
    }
  }

  expect_failures = [var.service_principals]
}

run "service_principal_sin_acciones_se_rechaza" {
  command = plan

  variables {
    service_principals = {
      "logs.us-east-1.amazonaws.com" = { actions = [] }
    }
  }

  expect_failures = [var.service_principals]
}

run "service_principal_con_accion_fuera_de_kms_se_rechaza" {
  command = plan

  variables {
    service_principals = {
      "logs.us-east-1.amazonaws.com" = { actions = ["logs:PutLogEvents"] }
    }
  }

  expect_failures = [var.service_principals]
}

run "service_principal_con_via_service_invalido_se_rechaza" {
  command = plan

  variables {
    service_principals = {
      "s3.amazonaws.com" = { via_service = ["s3"] }
    }
  }

  expect_failures = [var.service_principals]
}

run "service_principal_con_encryption_context_vacio_se_rechaza" {
  command = plan

  variables {
    service_principals = {
      "logs.us-east-1.amazonaws.com" = {
        encryption_context = { "aws:logs:arn" = "" }
      }
    }
  }

  expect_failures = [var.service_principals]
}
