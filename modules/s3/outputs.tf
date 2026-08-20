output "bucket_arn" {
  description = "ARN completo del bucket S3"
  value       = aws_s3_bucket.this.arn
}

output "bucket_id" {
  description = "Nombre del bucket (identico a bucket_name, expuesto por consistencia con otros modulos del catalogo)"
  value       = aws_s3_bucket.this.id
}

output "bucket_regional_domain_name" {
  description = "Nombre de dominio regional del bucket (para usar como origin en CloudFront, por ejemplo)"
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "has_custom_policy" {
  description = "Si se proporciono custom_bucket_policy. Marca la policy como 'no solo lo que impone el modulo', util para auditar que buckets tienen statements adicionales"
  value       = var.custom_bucket_policy != null
}

output "sse_algorithm" {
  description = "Algoritmo de cifrado efectivo: aws:kms o AES256, segun si se proveyo kms_key_arn"
  value       = local.sse_algorithm
}

output "versioning_enabled" {
  description = "Siempre true: expuesto para que una politica automatizada pueda afirmarlo sin leer el codigo del consumidor"
  value       = true
}