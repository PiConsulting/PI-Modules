###############################################################################
# Tests de contrato, plan-only. Sin credenciales, sin recursos, sin coste.
#
#   terraform test
#
# aws_s3_bucket.this.arn no se conoce en plan (recien existe tras el apply), y
# el Deny de TLS-only lo referencia en sus resources -por eso el JSON fusionado
# de la bucket policy sale "(known after apply)" aqui. Los tests de las 4
# preconditions anti-lockout no verifican el CONTENIDO del JSON: verifican que
# el plan del recurso falle o pase, igual que hace iam-role con sus tres
# preconditions de escalada.
#
# Las politicas de prueba se arman con jsonencode, no con
# aws_iam_policy_document -mismo motivo que iam-role: ejercitar la forma cruda
# que jsondecode() va a normalizar en locals.tf.
###############################################################################

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:user/test"
      id         = "111122223333"
      user_id    = "AIDACKCEVSQ6C2EXAMPLE"
    }
  }
}

variables {
  bucket_name = "test-dev-bucket"
  environment = "dev"
}

###############################################################################
# Comportamiento por defecto
###############################################################################

run "defaults" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning debe estar siempre activo, sin variable."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Sin kms_key_arn, el cifrado debe caer a SSE-S3 (AES256): nunca sin cifrar."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == false
    error_message = "bucket_key_enabled solo tiene sentido con SSE-KMS."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "Las 4 protecciones del Public Access Block deben estar activas siempre, sin variable."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "Object Ownership debe ser BucketOwnerEnforced: no negociable, deshabilita ACLs."
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy por defecto debe ser false: es la proteccion de datos real."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket.this.tags["Name"] == "test-dev-bucket",
      aws_s3_bucket.this.tags["Environment"] == "dev",
      aws_s3_bucket.this.tags["ManagedBy"] == "terraform",
      aws_s3_bucket.this.tags["Module"] == "s3",
    ])
    error_message = "El minimo impuesto de tags (Name, Environment, ManagedBy, Module) debe estar presente."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule) == 2
    error_message = "Sin lifecycle_transitions, solo deben existir las 2 reglas fijas del modulo."
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.this.rule : r
      if r.id == "noncurrent-version-expiration"
    ]).noncurrent_version_expiration[0].noncurrent_days == 30
    error_message = "El default de noncurrent_version_expiration_days debe ser 30."
  }

  assert {
    condition = one([
      for r in aws_s3_bucket_lifecycle_configuration.this.rule : r
      if r.id == "abort-incomplete-multipart-upload"
    ]).abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "El default de abort_incomplete_multipart_upload_days debe ser 7."
  }
}

###############################################################################
# Cifrado condicional
###############################################################################

run "kms_key_provisto_cambia_a_sse_kms" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "Con kms_key_arn, el algoritmo debe ser aws:kms."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == true
    error_message = "Con SSE-KMS, bucket_key_enabled debe activarse: reduce el costo de llamadas a KMS."
  }
}

run "kms_key_arn_con_formato_invalido_se_rechaza" {
  command = plan

  variables {
    kms_key_arn = "no-es-un-arn"
  }

  expect_failures = [var.kms_key_arn]
}

###############################################################################
# Ciclo de vida
###############################################################################

run "lifecycle_con_transiciones_crea_regla_opcional" {
  command = plan

  variables {
    lifecycle_transitions = [
      { days = 90, storage_class = "STANDARD_IA" },
      { days = 180, storage_class = "GLACIER" },
    ]
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule) == 3
    error_message = "Con lifecycle_transitions no vacio debe aparecer la tercera regla opcional."
  }

  assert {
    condition = length([
      for r in aws_s3_bucket_lifecycle_configuration.this.rule : r
      if r.id == "opt-in-storage-class-transitions"
    ]) == 1
    error_message = "La regla opcional debe traer ese id fijo."
  }

  assert {
    condition = length(one([
      for r in aws_s3_bucket_lifecycle_configuration.this.rule : r
      if r.id == "opt-in-storage-class-transitions"
    ]).transition) == 2
    error_message = "Cada entrada de lifecycle_transitions debe producir un bloque transition."
  }
}

run "standard_ia_antes_de_30_dias_se_rechaza" {
  command = plan

  variables {
    lifecycle_transitions = [
      { days = 15, storage_class = "STANDARD_IA" },
    ]
  }

  expect_failures = [var.lifecycle_transitions]
}

run "transiciones_duplicadas_a_la_misma_storage_class_se_rechazan" {
  command = plan

  variables {
    lifecycle_transitions = [
      { days = 90, storage_class = "GLACIER" },
      { days = 180, storage_class = "GLACIER" },
    ]
  }

  expect_failures = [var.lifecycle_transitions]
}

run "storage_class_invalida_se_rechaza" {
  command = plan

  variables {
    lifecycle_transitions = [
      { days = 90, storage_class = "COLD_STORAGE" },
    ]
  }

  expect_failures = [var.lifecycle_transitions]
}

run "noncurrent_version_expiration_fuera_de_rango_se_rechaza" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 5000
  }

  expect_failures = [var.noncurrent_version_expiration_days]
}

run "abort_incomplete_multipart_fuera_de_rango_se_rechaza" {
  command = plan

  variables {
    abort_incomplete_multipart_upload_days = 0
  }

  expect_failures = [var.abort_incomplete_multipart_upload_days]
}

###############################################################################
# Logging
###############################################################################

run "logging_target_bucket_igual_al_propio_se_rechaza" {
  command = plan

  variables {
    logging_target_bucket = "test-dev-bucket"
  }

  expect_failures = [var.logging_target_bucket]
}

run "logging_target_prefix_sin_target_bucket_se_rechaza" {
  command = plan

  variables {
    logging_target_prefix = "logs/"
  }

  expect_failures = [var.logging_target_prefix]
}

run "logging_target_bucket_valido_se_permite" {
  command = plan

  variables {
    logging_target_bucket = "test-dev-bucket-logs"
    logging_target_prefix = "logs/test-dev-bucket/"
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "test-dev-bucket"
    error_message = "Un logging_target_bucket distinto del propio debe aceptarse sin afectar el bucket principal."
  }
}

###############################################################################
# custom_bucket_policy: las 4 preconditions anti-lockout
###############################################################################

run "sid_reservado_colisiona_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "DenyInsecureTransport"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::111122223333:root" }
        Action    = "s3:GetObject"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_s3_bucket_policy.this]
}

run "deny_con_notprincipal_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid          = "BloquearMenosUno"
        Effect       = "Deny"
        NotPrincipal = { AWS = "arn:aws:iam::111122223333:role/admin" }
        Action       = "s3:*"
        Resource     = "*"
      }]
    })
  }

  expect_failures = [aws_s3_bucket_policy.this]
}

run "principal_comodin_sin_condicion_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "AccesoPublico"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_s3_bucket_policy.this]
}

run "s3_wildcard_a_principal_externo_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "ControlTotalExterno"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::999988887777:root" }
        Action    = "s3:*"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_s3_bucket_policy.this]
}

run "putbucketpolicy_a_principal_externo_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "ReescribirPolicyExterno"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::999988887777:root" }
        Action    = "s3:PutBucketPolicy"
        Resource  = "*"
      }]
    })
  }

  expect_failures = [aws_s3_bucket_policy.this]
}

###############################################################################
# custom_bucket_policy: casos legitimos que NO deben rechazarse
###############################################################################

run "principal_comodin_con_condicion_se_permite" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "SoloDesdeElVPCE"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:SourceVpce" = "vpce-0123456789abcdef0"
          }
        }
      }]
    })
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "test-dev-bucket"
    error_message = "Un Principal comodin acotado por Condition es legitimo -mismo patron que logging.s3.amazonaws.com necesita- y debe permitirse."
  }
}

run "s3_wildcard_a_cuenta_propia_se_permite" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "AdminTotalDeLaCuentaPropia"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::111122223333:root" }
        Action    = "s3:*"
        Resource  = "*"
      }]
    })
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "test-dev-bucket"
    error_message = "s3:* concedido a la PROPIA cuenta (coincide con local.account_id mockeado) no es control externo y debe permitirse."
  }
}

run "custom_policy_json_invalido_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = "{ esto no es json"
  }

  expect_failures = [var.custom_bucket_policy]
}

run "custom_policy_sin_statement_se_rechaza" {
  command = plan

  variables {
    custom_bucket_policy = jsonencode({ Version = "2012-10-17" })
  }

  expect_failures = [var.custom_bucket_policy]
}

###############################################################################
# Validaciones basicas de bucket_name / environment
###############################################################################

run "bucket_name_muy_corto_se_rechaza" {
  command = plan

  variables {
    bucket_name = "ab"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_con_mayusculas_se_rechaza" {
  command = plan

  variables {
    bucket_name = "Test-Dev-Bucket"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_con_puntos_dobles_se_rechaza" {
  command = plan

  variables {
    bucket_name = "test..dev-bucket"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_con_formato_ip_se_rechaza" {
  command = plan

  variables {
    bucket_name = "192.168.5.4"
  }

  expect_failures = [var.bucket_name]
}

run "entorno_invalido_se_rechaza" {
  command = plan

  variables {
    environment = "qa2"
  }

  expect_failures = [var.environment]
}