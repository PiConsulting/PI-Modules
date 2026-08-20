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
| [aws_kms_alias.additional](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_description"></a> [description](#input\_description) | Que cifra esta clave | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Enorno de despliegue | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Nombre del componente, SIN el entorno: el modulo lo antepone al componer el alias (alias/<entorno>/<nombre>) y el tag Name (<entorno>-<nombre>-kms). Diverge a proposito de la convencion <cliente>-<entorno>-<componente> de iam-role y sg: el espacio de nombres de alias de KMS es plano por region, asi que sin ese prefijo dev y prod en la misma cuenta colisionarian. | `string` | n/a | yes |
| <a name="input_additional_aliases"></a> [additional\_aliases](#input\_additional\_aliases) | Alias extra, SIN el prefijo alias/ (lo añade el módulo). Los alias son gratuitos e ilimitados en la práctica; el caso real es la migración entre claves, donde el alias antiguo apunta temporalmente a la nueva. | `set(string)` | `[]` | no |
| <a name="input_deletion_window_in_days"></a> [deletion\_window\_in\_days](#input\_deletion\_window\_in\_days) | Días que la clave permanece en PendingDeletion antes de eliminarse. El valor por defecto es el máximo para permitir recuperación mediante kms:CancelKeyDeletion. CUIDADO: la clave sigue generando costos durante este período. | `number` | `30` | no |
| <a name="input_extra_policy_json"></a> [extra\_policy\_json](#input\_extra\_policy\_json) | Statements adicionales de la key policy: el .json de un aws\_iam\_policy\_document construido en el root, no JSON escrito a mano. Se AÑADEN a los statements del módulo, no los reemplazan. El caso real es el acceso cross-account condicionado. El módulo inspecciona este documento y lo rechaza en plan si compromete el acceso a la propia clave. | `string` | `null` | no |
| <a name="input_is_enabled"></a> [is\_enabled](#input\_is\_enabled) | Una clave deshabilitada no cifra ni descifra, pero no se borra ni se pierde. Es la palanca de contención ante un compromiso. Ponerlo en false rompe todo lo que dependa de la clave y el fallo no aparece en ningún log de aplicación: úsarlo a conciencia | `bool` | `true` | no |
| <a name="input_key_administrators"></a> [key\_administrators](#input\_key\_administrators) | ARNs de roles o usuarios IAM que administran el ciclo de vida de la clave: crear, describir, etiquetar, habilitar, programar y cancelar el borrado. NO reciben ninguna operación criptográfica. Separación de funciones: quien administra la clave no debería poder leer el dato cifrado con ella. Si un principal necesita ambas cosas, se lista también en key\_users, y que esté explícito es el punto. | `list(string)` | `[]` | no |
| <a name="input_key_users"></a> [key\_users](#input\_key\_users) | ARNs de roles o usuarios IAM que usan la clave para cifrar y descifrar. Genera DOS statements: el criptográfico (Encrypt, Decrypt, ReEncrypt*, GenerateDataKey*, DescribeKey) y el de grants (CreateGrant, ListGrants, RevokeGrant) acotado con kms:GrantIsForAWSResource. Sin el segundo, un ASG con EBS cifrado no lanza instancias, RDS no crea el cluster y Lambda no configura el cifrado en reposo, todo con errores que no mencionan la palabra grant. | `list(string)` | `[]` | no |
| <a name="input_multi_region"></a> [multi\_region](#input\_multi\_region) | Crea la clave como primaria multirregión, replicable después con el módulo kms-replica. INMUTABLE: se fija en la creación y no se convierte. Cambiarlo destruye y recrea la clave, y todo el dato cifrado con la anterior queda ilegible. Por eso se expone en v1 aunque hoy no se use: el coste de tenerlo es una variable booleana; el de no tenerlo es recifrar todo el dato del cliente. | `bool` | `false` | no |
| <a name="input_rotation_period_in_days"></a> [rotation\_period\_in\_days](#input\_rotation\_period\_in\_days) | Periodo de rotación automática del material criptográfico. La rotación siempre está activa. KMS conserva el material anterior para descifrar datos ya cifrados. | `number` | `365` | no |
| <a name="input_service_principals"></a> [service\_principals](#input\_service\_principals) | Principales de servicio de AWS con acceso directo a la clave, indexados por el<br/>principal completo. El módulo inyecta siempre la condición<br/>aws:SourceAccount = <cuenta actual>; los campos opcionales acotan más.<br/> <br/>  service\_principals = {<br/>    "logs.us-east-1.amazonaws.com" = {<br/>      encryption\_context = {<br/>        "aws:logs:arn" = "arn:aws:logs:us-east-1:444455556666:log-group:*"<br/>      }<br/>    }<br/>    "s3.amazonaws.com" = {<br/>      via\_service = ["s3.us-east-1.amazonaws.com"]<br/>      source\_arns = ["arn:aws:s3:::acme-prod-data"]<br/>    }<br/>  }<br/> <br/>actions            Acciones concedidas. El default cubre el uso criptográfico normal.<br/>                   kms:CreateGrant NO está en el default: si un servicio lo necesita<br/>                   (poco común fuera de key\_users), se pide explícito en actions y el<br/>                   módulo lo separa en su propio statement con la condición<br/>                   kms:GrantIsForAWSResource = true, igual que hace con key\_users.<br/>via\_service        Condición kms:ViaService: la clave solo se usa a través de ese servicio.<br/>source\_arns        Condición aws:SourceArn (ArnLike): acota el recurso concreto que la usa.<br/>encryption\_context Condiciones kms:EncryptionContext:<clave>, una por entrada del mapa. | <pre>map(object({<br/>    actions            = optional(list(string), ["kms:Decrypt", "kms:Encrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"])<br/>    via_service        = optional(list(string), [])<br/>    source_arns        = optional(list(string), [])<br/>    encryption_context = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Etiquetas adicionales | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_additional_alias_names"></a> [additional\_alias\_names](#output\_additional\_alias\_names) | Map de alias adicionales creados |
| <a name="output_alias_arn"></a> [alias\_arn](#output\_alias\_arn) | ARN del alias principal |
| <a name="output_alias_name"></a> [alias\_name](#output\_alias\_name) | Nombre del alias principal (alias/<entorno>/<nombre>) |
| <a name="output_has_policy_override"></a> [has\_policy\_override](#output\_has\_policy\_override) | Si se proporcionó extra\_policy\_json. Indica que hay statements custom además de los modelados |
| <a name="output_is_enabled"></a> [is\_enabled](#output\_is\_enabled) | Si la clave está habilitada para operaciones criptográficas |
| <a name="output_key_administrators_count"></a> [key\_administrators\_count](#output\_key\_administrators\_count) | Número de principales con permisos de administración (lifecycle, no crypto) |
| <a name="output_key_arn"></a> [key\_arn](#output\_key\_arn) | ARN completo de la clave KMS |
| <a name="output_key_id"></a> [key\_id](#output\_key\_id) | ID único de la clave KMS (UUID) |
| <a name="output_key_users_count"></a> [key\_users\_count](#output\_key\_users\_count) | Número de principales con permisos criptográficos (Encrypt, Decrypt, etc.) |
| <a name="output_multi_region"></a> [multi\_region](#output\_multi\_region) | Si la clave es multirregión |
| <a name="output_rotation_enabled"></a> [rotation\_enabled](#output\_rotation\_enabled) | Si la rotación automática está habilitada (siempre true en este módulo) |
| <a name="output_rotation_period_in_days"></a> [rotation\_period\_in\_days](#output\_rotation\_period\_in\_days) | Periodo de rotación automática en días |
| <a name="output_service_principals_count"></a> [service\_principals\_count](#output\_service\_principals\_count) | Número de service principals configurados |
| <a name="output_unscoped_service_principals"></a> [unscoped\_service\_principals](#output\_unscoped\_service\_principals) | Service principals que solo tienen aws:SourceAccount (sin via\_service, source\_arns o encryption\_context). En prod debería estar vacío |
<!-- END_TF_DOCS -->