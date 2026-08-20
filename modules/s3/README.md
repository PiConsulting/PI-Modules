# Módulo S3

Crea un bucket S3 privado, cifrado y con lifecycle mínimo por defecto: primitivo componible sin conocer el caso de uso final del consumidor (data lake, eventos serverless, storage de aplicación).

## Características

- **Privado sin excepción**: `public_access_block` con las 4 protecciones activas, sin variable de escape
- **Cifrado siempre activo**: SSE-KMS si se provee `kms_key_arn`, fallback automático a SSE-S3 (AES256) — nunca un bucket sin cifrar
- **TLS-only**: statement fijo (`aws:SecureTransport = false` → Deny), sin escape
- **Versioning siempre activo**, sin variable de desactivación
- **Object Ownership `BucketOwnerEnforced`** fijo: ACLs deshabilitadas
- **Lifecycle mínimo por defecto**: expiración de versiones no-actuales y abort de multipart uploads incompletos, para evitar crecimiento de costo invisible
- **`custom_bucket_policy`** aditiva, con 4 preconditions anti-lockout/anti-exposición (mismo patrón que `extra_policy_json` en `kms`)

## Seguridad

### Validaciones en `terraform plan`

`custom_bucket_policy` pasa por 4 preconditions antes de fusionarse con los statements fijos del módulo:

1. **Colisión de Sid**: pisaría en silencio un statement del módulo (p. ej. `DenyInsecureTransport`)
2. **Deny + NotPrincipal**: vector de lockout que deniega a todos menos a los listados, incluido el dueño del bucket
3. **Principal wildcard sin condición**: mismo agujero que `public_access_block` cierra por otra vía
4. **`s3:PutBucketPolicy` a un principal externo**: cesión de control de la policy a otra cuenta

## Lo que este módulo NO hace

- **No soporta Object Lock (WORM).** Fuera de v1 — se agrega cuando exista un requisito real de compliance.
- **No soporta replicación cross-region (CRR).** Fuera de v1 (YAGNI).
- **No soporta hosting estático directo (website endpoint).** Incompatible con `public_access_block` fijo.
- **No permite desactivar versioning, TLS-only ni `public_access_block`.** Son postura del módulo, no opciones.
- **No resuelve la unicidad global de `bucket_name`.** Es responsabilidad del root / convención de equipo.
- **No aplica transiciones de storage class por defecto.** `lifecycle_transitions` es opt-in, sin default.

## Uso básico

```hcl
module "app_data" {
  source = "../../modules/s3"

  bucket_name = "acme-prod-app-data"
  environment = "prod"
}
```

## Con SSE-KMS

```hcl
module "app_data" {
  source = "../../modules/s3"

  bucket_name = "acme-prod-app-data"
  environment = "prod"

  kms_key_arn = module.kms.key_arn
}
```

## Con lifecycle transitions y policy custom

```hcl
data "aws_iam_policy_document" "logs_delivery" {
  statement {
    sid    = "S3ServerAccessLogsPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::acme-prod-logs/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = ["123456789012"]
    }
  }
}

module "logs" {
  source = "../../modules/s3"

  bucket_name = "acme-prod-logs"
  environment = "prod"

  custom_bucket_policy = data.aws_iam_policy_document.logs_delivery.json

  lifecycle_transitions = [
    {
      days          = 90
      storage_class = "STANDARD_IA"
    },
    {
      days          = 180
      storage_class = "GLACIER"
    },
  ]
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.9 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0, < 7.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0, < 7.0 |

## Resources

| Name | Type |
|------|------|
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Nombre completo y global del bucket S3. Obligatorio,sin default: el modulo no resuelve la unicidad global de nombres. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Entorno de despliegue | `string` | n/a | yes |
| <a name="input_abort_incomplete_multipart_upload_days"></a> [abort\_incomplete\_multipart\_upload\_days](#input\_abort\_incomplete\_multipart\_upload\_days) | Dias que un multipart upload incompleto (interrumpido por un cliente, un timeout, un crash) permanece antes de abortarse y liberar el storage que ya ocupaba. Sin este limite, uploads fallidos que nadie completo ni cancelo se facturan indefinidamente sin aparecer en ningun listado normal de objetos. | `number` | `7` | no |
| <a name="input_custom_bucket_policy"></a> [custom\_bucket\_policy](#input\_custom\_bucket\_policy) | Statements adicionales de la bucket policy: el .json de un aws\_iam\_policy\_document construido en el root, no JSON escrito a mano. Se AÑADEN a los statements del modulo (deny de transporte inseguro y cualquier otro statement base), nunca los reemplazan. Casos reales: la bucket policy que necesita el destino de server access logging (logging.s3.amazonaws.com), o la policy de Origin Access Control para CloudFront. El modulo inspecciona este documento y lo rechaza en plan si compromete la seguridad base del bucket. | `string` | `null` | no |
| <a name="input_force_destroy"></a> [force\_destroy](#input\_force\_destroy) | permite terraform destroy con objetos dentro del bucket (los borra primero). Default en false: proteccion de datos. | `bool` | `false` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN de la CMK de KMS para SSE-KMS (normalmente el output key\_arn del modulo kms). Si se omite, el bucket cae automaticamente a SSE-S3 (AES256): nunca queda sin cifrar | `string` | `null` | no |
| <a name="input_lifecycle_transitions"></a> [lifecycle\_transitions](#input\_lifecycle\_transitions) | Transiciones opcionales de storage class por antiguedad del objeto (ej. a STANDARD\_IA a los 90 dias, a GLACIER a los 180). Vacia por defecto: el modulo no impone abaratamiento automatico, depende del patron de acceso de cada caso de uso. | <pre>list(object({<br/>    days          = number<br/>    storage_class = string<br/>  }))</pre> | `[]` | no |
| <a name="input_logging_target_bucket"></a> [logging\_target\_bucket](#input\_logging\_target\_bucket) | Nombre del bucket destino de server access logging. Si se omite, el bucket no genera logs de acceso via este mecanismo (S3 registra eventos via CloudTrail data events) | `string` | `null` | no |
| <a name="input_logging_target_prefix"></a> [logging\_target\_prefix](#input\_logging\_target\_prefix) | Prefijo de key para los logs dentro de logging\_target\_bucket (ej. 'logs/mi-bucket/'). Solo tiene efecto si logging\_target\_bucket esta definido. | `string` | `null` | no |
| <a name="input_noncurrent_version_expiration_days"></a> [noncurrent\_version\_expiration\_days](#input\_noncurrent\_version\_expiration\_days) | Dias que una version no-actual de un objeto se conserva antes de expirar (eliminacion definitiva). Con versioning siempre activo, sin este limite el bucket crece de forma invisible: cada sobreescritura o borrado deja una version anterior facturando para siempre. | `number` | `30` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | tags adicionales | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN completo del bucket S3 |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Nombre del bucket (identico a bucket\_name, expuesto por consistencia con otros modulos del catalogo) |
| <a name="output_bucket_regional_domain_name"></a> [bucket\_regional\_domain\_name](#output\_bucket\_regional\_domain\_name) | Nombre de dominio regional del bucket (para usar como origin en CloudFront, por ejemplo) |
| <a name="output_has_custom_policy"></a> [has\_custom\_policy](#output\_has\_custom\_policy) | Si se proporciono custom\_bucket\_policy. Marca la policy como 'no solo lo que impone el modulo', util para auditar que buckets tienen statements adicionales |
| <a name="output_sse_algorithm"></a> [sse\_algorithm](#output\_sse\_algorithm) | Algoritmo de cifrado efectivo: aws:kms o AES256, segun si se proveyo kms\_key\_arn |
| <a name="output_versioning_enabled"></a> [versioning\_enabled](#output\_versioning\_enabled) | Siempre true: expuesto para que una politica automatizada pueda afirmarlo sin leer el codigo del consumidor |
<!-- END_TF_DOCS -->

## Notas

- **`bucket_name` es obligatorio, sin default ni composición interna**: a diferencia del alias de `kms`, un nombre de bucket S3 es único a nivel global de AWS, y el módulo no puede resolver esa unicidad de forma segura.
- **`custom_bucket_policy` es aditiva, nunca sustitutiva**: se fusiona con los statements fijos del módulo vía `source_policy_documents`.
- **Enforcement de header de cifrado descartado deliberadamente**: es redundante frente al cifrado por defecto del bucket y arriesga romper clientes/SDKs viejos que no mandan el header explícito.

## Checklist antes de producción

**Seguridad**

- [ ] `custom_bucket_policy`, si se usa, viene de `data.aws_iam_policy_document`, no de JSON escrito a mano
- [ ] Ningún statement de `custom_bucket_policy` depende de una precondition del módulo para no exponer el bucket — las preconditions son la última línea de defensa, no el diseño

**Operación**

- [ ] `bucket_name` sigue la convención de naming/unicidad global acordada por el equipo (el módulo no la valida)
- [ ] `force_destroy` queda en `false` en producción; solo se activa explícitamente en entornos efímeros
- [ ] `noncurrent_version_expiration_days` acorde a los requisitos de retención/compliance del cliente

**Diseño**

- [ ] Si se necesita server access logging, `logging_target_bucket`/`logging_target_prefix` apuntan a un bucket creado con este mismo módulo, con la bucket policy que `logging.s3.amazonaws.com` requiere vía `custom_bucket_policy`

## Referencias

- [Amazon S3 Security Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [Bucket Policy Examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-bucket-policies.html)
- [S3 Lifecycle Configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
