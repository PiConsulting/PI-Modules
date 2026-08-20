data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = local.bucket_key_enabled
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_logging" "this" {
  count = var.logging_target_bucket != null ? 1 : 0

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.logging_target_bucket
  target_prefix = coalesce(var.logging_target_prefix, "")
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  depends_on = [aws_s3_bucket_versioning.this]
  bucket     = aws_s3_bucket.this.id

  rule {
    id     = "noncurrent-version-expiration"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  dynamic "rule" {
    for_each = length(var.lifecycle_transitions) > 0 ? [1] : []

    content {
      id     = "opt-in-storage-class-transitions"
      status = "Enabled"

      filter {}

      dynamic "transition" {
        for_each = var.lifecycle_transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  source_policy_documents = var.custom_bucket_policy == null ? [] : [var.custom_bucket_policy]

  statement {
    sid    = local.sid_deny_insecure_transport
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # Orden explicito: si la policy se aplicara ANTES que public_access_block,
  # hay una ventana real (aunque breve) en el primer apply donde el bucket
  # queda gobernado solo por la policy, sin las 4 protecciones activas.
  depends_on = [aws_s3_bucket_public_access_block.this]

  lifecycle {
    # PRECONDITION 1: colisión de Sid con los reservados del módulo
    precondition {
      condition     = length(local.custom_sid_collisions) == 0
      error_message = <<-EOT
        custom_bucket_policy usa Sids reservados por el modulo: ${join(", ", local.custom_sid_collisions)}
        Reservados: ${join(", ", local.reserved_sids)}

        IMPACTO: aws_iam_policy_document resuelve la fusion POR Sid. Un Sid duplicado
        sustituye al statement del modulo SIN emitir ningun error. Si pisas
        "${local.sid_deny_insecure_transport}" perdes la proteccion TLS-only sin que
        nada te avise en el plan.

        SOLUCION: renombra el Sid de tu statement.
      EOT
    }

    # PRECONDITION 2: Deny + NotPrincipal
    precondition {
      condition     = length(local.custom_deny_notprincipal) == 0
      error_message = <<-EOT
        custom_bucket_policy combina Effect: Deny con NotPrincipal en: ${join(", ", local.custom_deny_notprincipal)}

        IMPACTO: un Deny con NotPrincipal deniega a TODOS menos a los listados, incluido
        el dueño del bucket. Un Deny explicito gana siempre sobre un Allow.

        SOLUCION: para denegar a principales concretos usa Deny + Principal.
      EOT
    }

    # PRECONDITION 3: Principal comodín sin condición
    precondition {
      condition     = length(local.custom_wildcard_principals) == 0
      error_message = <<-EOT
        custom_bucket_policy concede Allow a un Principal comodin sin Condition en: ${join(", ", local.custom_wildcard_principals)}

        IMPACTO: cualquier cuenta de AWS del mundo puede acceder a este bucket — el mismo
        agujero que public_access_block cierra por otra via.

        SOLUCION: nombra los principales, o acota el comodin con una condicion
        (aws:PrincipalOrgID, aws:SourceAccount, aws:SourceVpce).
      EOT
    }

    # PRECONDITION 4: control cedido a un principal externo
    precondition {
      condition     = length(local.custom_external_control) == 0
      error_message = <<-EOT
        custom_bucket_policy concede s3:* o s3:PutBucketPolicy a un principal externo en: ${join(", ", local.custom_external_control)}

        IMPACTO: un principal de otra cuenta puede reescribir la bucket policy entera y
        dejarte fuera de forma permanente, o exponer el bucket sin que lo notes.

        SOLUCION: s3:PutBucketPolicy solo para principales de esta cuenta (${local.account_id}).
        A un tercero se le conceden operaciones puntuales, nunca el control de la politica.
      EOT
    }
  }
}


