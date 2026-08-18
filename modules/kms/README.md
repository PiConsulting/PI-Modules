# Módulo KMS

Crea y gestiona claves KMS con key policy segura por defecto, separación de funciones (administración vs uso criptográfico), y protecciones contra lockout.

## Características

- **Rotación automática habilitada**: período configurable (default 365 días)
- **Separación de funciones**: administradores de la clave vs usuarios criptográficos
- **Protección confused deputy**: `aws:SourceAccount` siempre inyectado en service principals
- **Anti-lockout**: delegación en IAM siempre activa, validaciones de políticas custom
- **Naming jerárquico**: aliases por entorno para evitar colisiones

## Seguridad

### Validaciones en `terraform plan`

El módulo detecta y rechaza:

1. **Colisión de Sid**: extra_policy_json que pisa statements del módulo
2. **Deny + NotPrincipal**: vector de lockout que sobrevive al statement raíz
3. **Principal wildcard sin condiciones**: clave utilizable por cualquier cuenta AWS
4. **kms:PutKeyPolicy a externos**: permite que otra cuenta reescriba la política

### Separación de funciones

- `key_administrators`: lifecycle (create, describe, tag, schedule deletion) — **SIN operaciones criptográficas**
- `key_users`: encrypt, decrypt, generate data keys + grants para servicios AWS

Administradores NO pueden leer datos cifrados por defecto. Si necesitan ambos roles, deben listarse explícitamente en ambas variables.

## Lo que este módulo NO hace

- **No soporta claves asimétricas ni de firma.** No expone `customer_master_key_spec` ni `key_usage`: la clave siempre es simétrica (`SYMMETRIC_DEFAULT`), pensada para cifrado, no para firmar/verificar.
- **No crea grants explícitos.** `key_users` recibe el permiso `kms:CreateGrant`, pero el grant en sí lo crea el servicio consumidor (ASG, RDS, Lambda) en el momento en que lo necesita, no el módulo.
- **No crea réplicas multi-región.** `multi_region = true` solo marca la clave como primaria replicable. Las réplicas se crean con `aws_kms_replica_key` en otra región, hoy fuera del módulo (fuera del catálogo hasta que exista `kms-replica`).
- **No permite desactivar la rotación.** `enable_key_rotation` está fijo en `true` sin variable de escape: es una postura del módulo, no una opción.
- **No valida permisos efectivos, solo la forma de la política.** Las preconditions detectan los patrones de lockout y exposición conocidos (colisión de Sid, `Deny+NotPrincipal`, wildcard sin condición, `PutKeyPolicy` externo), igual que `iam-role`; no sustituyen a IAM Access Analyzer.
- **`extra_policy_json` no tolera `Statement` como objeto suelto de forma confiable.** La normalización de `locals.tf` lo acepta para las preconditions de seguridad, pero `source_policy_documents` (main.tf) exige que `Statement` sea siempre un array — con un objeto suelto el plan falla con un error de Go, no con el mensaje del módulo. Construir `extra_policy_json` con `data.aws_iam_policy_document` (como recomienda la descripción de la variable) evita el caso: ese data source siempre emite `Statement` como lista.

## Uso básico

```hcl
module "app_data_key" {
  source = "../../modules/kms"

  name        = "app-data"
  environment = "prod"
  description = "Cifra datos de aplicación en RDS y S3. Usado por rol app-backend-prod"

  key_administrators = [
    "arn:aws:iam::123456789012:role/security-team"
  ]

  key_users = [
    "arn:aws:iam::123456789012:role/app-backend-prod"
  ]

  tags = {
    Project   = "acme-app"
    Owner     = "platform-team"
    CostCenter = "engineering"
  }
}
```

## Service principals

```hcl
module "logs_key" {
  source = "../../modules/kms"

  name        = "cloudwatch-logs"
  environment = "prod"
  description = "Cifra CloudWatch Logs del entorno prod"

  service_principals = {
    "logs.us-east-1.amazonaws.com" = {
      encryption_context = {
        "aws:logs:arn" = "arn:aws:logs:us-east-1:123456789012:log-group:*"
      }
    }
  }
}
```

## Política custom (cross-account)

```hcl
data "aws_iam_policy_document" "cross_account" {
  statement {
    sid    = "AllowDevAccountDecrypt"
    effect = "Allow"
    
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::999888777666:root"]
    }
    
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    
    resources = ["*"]
    
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.us-east-1.amazonaws.com"]
    }
  }
}

module "shared_key" {
  source = "../../modules/kms"

  name               = "cross-account-s3"
  environment        = "prod"
  description        = "Clave compartida con cuenta dev para buckets específicos"
  extra_policy_json  = data.aws_iam_policy_document.cross_account.json
}
```

## Inputs

| Variable | Tipo | Default | Descripción |
|----------|------|---------|-------------|
| `name` | `string` | - | Nombre del componente (sin entorno, se añade automáticamente) |
| `environment` | `string` | - | Entorno: dev, stg, prod |
| `description` | `string` | - | Qué cifra esta clave (mínimo 10 caracteres) |
| `deletion_window_in_days` | `number` | `30` | Días en PendingDeletion antes de borrado definitivo |
| `rotation_period_in_days` | `number` | `365` | Periodo de rotación automática (90-2560) |
| `multi_region` | `bool` | `false` | Crea clave primaria multirregión (INMUTABLE) |
| `is_enabled` | `bool` | `true` | Habilita/deshabilita operaciones criptográficas |
| `key_administrators` | `list(string)` | `[]` | ARNs IAM con permisos de administración |
| `key_users` | `list(string)` | `[]` | ARNs IAM con permisos criptográficos |
| `service_principals` | `map(object)` | `{}` | Service principals de AWS con acceso directo |
| `additional_aliases` | `set(string)` | `[]` | Alias extra (para migraciones) |
| `extra_policy_json` | `string` | `null` | Statements adicionales (output de aws_iam_policy_document) |
| `tags` | `map(string)` | `{}` | Tags adicionales |

## Outputs

| Output | Descripción |
|--------|-------------|
| `key_id` | UUID de la clave |
| `key_arn` | ARN completo de la clave |
| `alias_name` | Nombre del alias principal |
| `alias_arn` | ARN del alias principal |
| `has_policy_override` | Si se usó extra_policy_json |
| `unscoped_service_principals` | Service principals sin condiciones adicionales (debería estar vacío en prod) |

## Observabilidad

Los outputs de "postura" permiten auditar configuraciones sin leer código:

```hcl
# Asegurar que en prod no hay service principals sin acotar
output "kms_audit" {
  value = {
    for k, mod in module.kms_keys :
    k => {
      unscoped_services = mod.unscoped_service_principals
      has_custom_policy = mod.has_policy_override
    }
  }
}
```

## Notas

- **Alias jerárquico**: `alias/<entorno>/<nombre>` evita colisiones entre entornos en la misma cuenta
- **Delegación IAM siempre activa**: el statement raíz nunca se omite, incluso con listas vacías
- **Grants automáticos**: key_users recibe permisos de grants con `kms:GrantIsForAWSResource`, necesario para ASG, RDS, Lambda
- **multi_region es inmutable**: cambiarlo destruye y recrea la clave (datos previos ilegibles)

## Checklist antes de producción

**Seguridad**

- [ ] `key_administrators` y `key_users` no se solapan salvo que sea intencional y esté documentado por qué
- [ ] Ningún principal aparece en `unscoped_service_principals` sin que se haya decidido conscientemente (esa condición mínima ya cierra confused-deputy, pero en prod conviene acotar con `via_service`/`source_arns`/`encryption_context`)
- [ ] `extra_policy_json`, si se usa, viene de `data.aws_iam_policy_document`, no de JSON escrito a mano
- [ ] `rotation_period_in_days` acorde a los requisitos de compliance del cliente

**Operación**

- [ ] `name` es solo el componente, sin entorno (p. ej. `app-data`, no `acme-prod-app-data`): el módulo antepone el entorno al construir el alias y el tag `Name`
- [ ] `deletion_window_in_days` en 30 para producción (7 solo en dev/test)
- [ ] Alias documentado y comunicado a los consumidores de la clave
- [ ] Probado que los servicios que dependen de `key_users` (ASG, RDS, Lambda) realmente lanzan recursos cifrados — es donde falla el grant si `kms:GrantIsForAWSResource` no está bien acotado

**Diseño**

- [ ] Si `is_enabled = false`, el motivo y el plan de reactivación están documentados
- [ ] `multi_region` decidido conscientemente: cambiarlo después destruye y recrea la clave, y el dato cifrado con la anterior queda ilegible

## Referencias

- [AWS KMS Best Practices](https://docs.aws.amazon.com/kms/latest/developerguide/best-practices.html)
- [Key Policies](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)
- [Grants](https://docs.aws.amazon.com/kms/latest/developerguide/grants.html)
