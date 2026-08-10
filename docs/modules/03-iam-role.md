# Módulo 3 · IAM Role

**Spec de diseño** · Estado: pendiente de implementación
Código: `modules/iam-role/`

---

## 0. Decisiones tomadas antes de escribir código

| Decisión | Elegido | Descartado |
|---|---|---|
| Políticas inline | `map(string)` con el `.json` de un `aws_iam_policy_document` del consumidor | Modelar statements como variables; aceptar ambos |
| Permissions boundary | Obligatorio, con exención escrita y justificada | Obligatorio sin escape; opcional con default `null` |
| Tipos de confianza en v1 | Servicios + cuentas con `external_id` obligatorio | OIDC federado; SAML; IRSA de EKS |
| Nombre del recurso | `name`, **no** `name_prefix` | `name_prefix` (lo que sí usa `sg`) |

**Nombre del módulo: `iam-role`**, no `iam`. El repositorio usa nombres cortos cuando son
inequívocos (`vpc`, `sg`, `kms`), pero `iam` a secas no dice si crea un rol, una política,
un usuario o un grupo. La ambigüedad cuesta más que los cinco caracteres.

---

## 1. Qué problema resuelve

IAM es donde una arquitectura bien diseñada se echa a perder en silencio. Un security
group mal puesto se ve en un diagrama; una política con `Action: "*"` sobre
`Resource: "*"` no se ve en ningún sitio y concede acceso total a la cuenta.

Cuatro fallos concretos, todos habituales:

**a) `*:*` por comodidad.** "Lo abrimos mientras depuramos" y queda seis meses. Es la
misma dinámica que el `0.0.0.0/0` en un security group, pero sin nada visual que lo delate.

**b) Confianza cross-account sin condición.** `trusted_accounts = ["111122223333"]` sin
más significa que **cualquiera** de esa cuenta con permiso de `sts:AssumeRole` puede asumir
tu rol. Es el *confused deputy*, el fallo que llevó a AWS a inventar el `ExternalId`. Un
módulo que lo hace fácil sin forzar una condición está facilitando una debilidad conocida.

**c) `iam:PassRole` sin restringir.** Es el vector de escalada de privilegios más común de
AWS: si puedo pasar cualquier rol a un servicio, puedo pasarme el rol de administrador y
ejecutar código con él. Casi nadie lo restringe porque casi nadie sabe que existe.

**d) Roles sin permissions boundary.** Sin él, un rol con permisos de crear roles puede
crear uno más privilegiado que él mismo. El boundary es el techo que hace que esa escalada
no sirva de nada.

El módulo convierte los cuatro en errores de `plan`.

### Sobre el valor real del módulo

Igual que `sg`: **es un módulo de disciplina.** No ahorra líneas de código frente a
escribir `aws_iam_role` a mano. Lo que aporta son las validaciones que no se pueden apagar,
el boundary obligatorio, la construcción correcta de la política de confianza y el
etiquetado consistente.

---

## 2. En qué arquitecturas se usa

En todas, y con más invocaciones que ningún otro módulo del catálogo. Un stack de ECS
Fargate necesita fácilmente cinco o seis roles distintos.

| Consumidor | Rol típico |
|---|---|
| `ecs-fargate` | Task execution role, task role |
| `lambda` | Execution role |
| `ec2` / `asg` | Instance role + instance profile |
| `rds-aurora` | Monitoring role, rol de exportación a S3 |
| `ci-cd` | Roles de plan y apply (con OIDC, que llega en v1.1) |
| `vpc` | Ya crea el suyo para flow logs, internamente |

Depende de: nada. Es un módulo hoja.
Lo consumen: prácticamente todos.

---

## 3. Buenas prácticas que debe cumplir

| Pilar | Requisito | Cómo se cumple |
|---|---|---|
| **Seguridad** | Menor privilegio verificable | `precondition` que rechaza `Allow` con `Action:*` sobre `Resource:*` |
| | Sin escalada vía `PassRole` | `precondition` que exige condición o recurso acotado cuando aparece `iam:PassRole` |
| | Sin confused deputy | `external_id` obligatorio cuando hay confianza cross-account |
| | Techo de permisos | `permissions_boundary_arn` obligatorio salvo exención escrita |
| | Sesiones acotadas | `max_session_duration` con default de 1 hora, no las 12 que permite AWS |
| **Excelencia operativa** | Nombres predecibles | `name` explícito; los nombres de rol aparecen en políticas de confianza de otras cuentas |
| | Trazabilidad | `local.tags` con `Module = "iam-role"`, igual que el resto del catálogo |
| | Sin políticas huérfanas | Políticas inline: se borran con el rol, no quedan sueltas en la cuenta |
| | Fallar en plan | Todo lo anterior son `validation` o `precondition`, nunca errores de `apply` |
| **Confiabilidad** | — | IAM es global y no tiene concepto de AZ. Único módulo del catálogo sin decisiones de resiliencia |
| **Costes** | — | IAM es gratuito |

---

## 4. Variables

### La decisión de interfaz que importa

```hcl
inline_policies = map(string)     # el .json, no los statements modelados
```

La alternativa —exponer `effect`, `actions`, `resources`, `conditions` como tipos de
variable y construir el documento con `dynamic` dentro del módulo— significa
**reimplementar el esquema de IAM en la interfaz del módulo**. Y ese esquema es enorme:
`sid`, `not_actions`, `not_resources`, `principals` con seis tipos, `condition` con
test/variable/values. Cada hueco que dejes es una limitación; cada hueco que tapes es
superficie que mantener.

Y no aporta seguridad, porque el consumidor ya tiene la herramienta que valida en tiempo
de plan:

```hcl
data "aws_iam_policy_document" "app" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${module.bucket.arn}/*"]
  }
}

module "role" {
  inline_policies = { app = data.aws_iam_policy_document.app.json }
}
```

Eso **no es JSON crudo**: es el mismo `aws_iam_policy_document`, solo que en el root, donde
vive el conocimiento del negocio. El consumidor conserva toda la expresividad y el módulo
no necesita saber nada de IAM.

Lo que sí hace el módulo con ese JSON es **inspeccionarlo y rechazarlo si viola la
política de la plataforma**. Eso es imponer, que es su trabajo.

### Interfaz completa

| Variable | Tipo | Default | Notas |
|---|---|---|---|
| `name` | `string` | — | `<cliente>-<entorno>-<rol>`. Máximo 64 caracteres (límite de IAM) |
| `environment` | `string` | — | `dev` \| `stg` \| `prod` |
| `description` | `string` | — | Sin default. Explica qué hace el rol, no que es un rol |
| `path` | `string` | `"/"` | Útil para organizar por equipo o por servicio |
| `max_session_duration` | `number` | `3600` | 1 hora. AWS permite hasta 12; el default no debe ser el máximo |
| **Confianza** | | | |
| `trusted_services` | `list(string)` | `[]` | `["ec2.amazonaws.com", "lambda.amazonaws.com"]` |
| `trusted_account_ids` | `list(string)` | `[]` | IDs de 12 dígitos |
| `external_id` | `string` | `null` | **Obligatorio** si hay `trusted_account_ids` |
| `trusted_source_account` | `string` | `null` | Condición `aws:SourceAccount` para principales de servicio |
| **Permisos** | | | |
| `managed_policy_arns` | `list(string)` | `[]` | ARNs de políticas gestionadas por AWS o por el cliente |
| `inline_policies` | `map(string)` | `{}` | Clave descriptiva → JSON de `aws_iam_policy_document` |
| `permissions_boundary_arn` | `string` | `null` | Obligatorio salvo exención |
| `boundary_exempt_reason` | `string` | `null` | Justificación escrita. Solo si no hay boundary |
| **Extras** | | | |
| `create_instance_profile` | `bool` | `false` | Necesario para EC2; inútil para Lambda o ECS |
| `tags` | `map(string)` | `{}` | |

### Validaciones

En `variable` (solo pueden mirar variables):

| Regla | Qué previene |
|---|---|
| `name` de 3 a 64 caracteres, patrón IAM | Fallo a mitad de `apply` |
| `environment` en `dev`/`stg`/`prod` | Proliferación de entornos |
| `description` de al menos 10 caracteres | Roles que nadie sabe para qué son |
| Al menos un `trusted_services` o un `trusted_account_ids` | Un rol que nadie puede asumir; no falla, simplemente no sirve |
| `external_id` presente y de ≥16 caracteres si hay `trusted_account_ids` | **Confused deputy** |
| `trusted_account_ids` con formato de 12 dígitos | Erratas silenciosas |
| `max_session_duration` entre 3600 y 43200 | Fuera de rango falla en `apply` |
| Boundary presente **o** `boundary_exempt_reason` de ≥20 caracteres | Roles sin techo de permisos, sin dejar rastro |

En `precondition` (pueden mirar `locals`, que es donde se decodifica el JSON):

| Regla | Qué previene |
|---|---|
| Ningún statement `Allow` con `Action:*` **y** `Resource:*` | Acceso total a la cuenta |
| `iam:PassRole` solo con `Resource` acotado o con `condition` | La escalada de privilegios más común de AWS |
| Ningún `sts:AssumeRole` con `Resource: "*"` | Pivotar a cualquier rol de la cuenta |

**Por qué `precondition` y no `validation`:** un bloque `validation` solo puede referenciar
variables, y estas comprobaciones necesitan `jsondecode` y normalización previa, que viven
en `locals`. La `precondition` del recurso sí puede leer `locals` y sigue disparándose en
`plan`.

### La normalización del JSON tiene trampa

`jsondecode` de una política devuelve estructuras irregulares: `Statement` puede ser un
objeto o una lista; `Action` y `Resource` pueden ser una cadena o una lista. La
normalización en `locals` tiene que cubrir los cuatro casos o las validaciones fallarán en
falso con políticas perfectamente válidas.

```hcl
locals {
  decoded_policies = { for k, v in var.inline_policies : k => jsondecode(v) }

  # Statement puede venir como objeto suelto o como lista
  all_statements = flatten([
    for k, doc in local.decoded_policies : [
      for s in(can(tolist(doc.Statement)) ? doc.Statement : [doc.Statement]) : merge(s, { _policy = k })
    ]
  ])

  # Action y Resource pueden ser string o lista
  normalized_statements = [
    for s in local.all_statements : {
      policy    = s._policy
      effect    = try(s.Effect, "Allow")
      actions   = can(tolist(try(s.Action, []))) ? try(s.Action, []) : [s.Action]
      resources = can(tolist(try(s.Resource, []))) ? try(s.Resource, []) : [s.Resource]
      has_condition = can(s.Condition)
    }
  ]
}
```

---

## 5. Outputs

| Output | Consumido por |
|---|---|
| `arn` | Casi todo: ECS, Lambda, RDS lo reciben directamente |
| `name` | Políticas de confianza escritas en otras cuentas |
| `id` | Equivale a `name`; se expone por compatibilidad de hábitos |
| `unique_id` | El ID interno de IAM. Útil en condiciones `aws:userid` |
| `instance_profile_arn` | Módulos de EC2/ASG. `null` si no se creó |
| `instance_profile_name` | Ídem |
| `assume_role_policy_json` | Auditoría y depuración: permite ver la política de confianza construida sin ir a la consola |
| `has_permissions_boundary` | Políticas automatizadas que verifican la postura, igual que `nat_gateway_mode` en `vpc` |

El patrón de devolver la **postura** además de los identificadores ya está en los tres
módulos. Permite que una revisión de arquitectura afirme "en prod, todo rol tiene
boundary" sin leer el código del consumidor.

---

## 6. Recursos que crea

| Recurso | Cantidad |
|---|---|
| `data.aws_iam_policy_document.assume_role` | 1 |
| `aws_iam_role` | 1 |
| `aws_iam_role_policy` | 1 por entrada de `inline_policies` |
| `aws_iam_role_policy_attachment` | 1 por ARN de `managed_policy_arns` |
| `aws_iam_instance_profile` | 1 si `create_instance_profile` |

Todo gratuito.

### Inline frente a política gestionada

El módulo crea las políticas propias como **inline** (`aws_iam_role_policy`), no como
`aws_iam_policy` independiente:

- Se borran con el rol. No quedan políticas huérfanas acumulándose en la cuenta, que es
  uno de los desórdenes clásicos de IAM.
- No son reutilizables entre roles, pero una política pensada para *este* rol no debería
  serlo.

**Limitación conocida:** AWS impone un máximo de 10.240 caracteres para el conjunto de
políticas inline de un rol. Con políticas grandes hay que pasar a `managed_policy_arns` y
crear la política fuera del módulo. Va documentado en el README.

### `name`, no `name_prefix` — al revés que `sg`

En `sg` era obligatorio `name_prefix` porque `create_before_destroy` hacía convivir dos
grupos y los nombres debían ser únicos. En IAM no aplica: no existe el `DependencyViolation`
que nos forzaba allí.

Y hay una razón positiva para el nombre exacto: los nombres de rol aparecen en políticas de
confianza escritas **en otras cuentas**, en documentación y en runbooks. Un sufijo aleatorio
los vuelve inmanejables.

Que dos módulos del mismo catálogo diverjan en esto está bien siempre que la razón esté
escrita. Sin escribirla, parece una inconsistencia.

---

## 7. Decisiones que el módulo NO debe tomar

| Decisión | De quién es |
|---|---|
| Qué permisos necesita la aplicación | Root: es conocimiento del negocio |
| Qué política de boundary existe y qué contiene | Módulo `iam-policy` o el equipo de seguridad. Este módulo recibe un ARN |
| Qué servicios pueden asumir el rol | Root |
| Si el egress... | (no aplica; IAM no tiene red) |
| Crear usuarios, grupos o claves de acceso | Fuera de alcance. Con Identity Center, los usuarios IAM casi nunca son la respuesta |
| Políticas gestionadas propias del cliente | Módulo `iam-policy`, cuando exista el caso |
| OIDC, SAML, IRSA de EKS | Fuera de v1. OIDC llegará con `ci-cd` |

Nota sobre atajos curados tipo `enable_ssm_access = true`: son de lo que más se agradece de
un módulo, pero son superficie. Fuera de v1, y se añaden cuando haya dos consumidores
reales pidiendo el mismo.

---

## 8. Errores comunes que evita

| Error | Consecuencia | Cómo lo evita |
|---|---|---|
| `Action:*` sobre `Resource:*` | Acceso total a la cuenta | `precondition` |
| `iam:PassRole` sin acotar | Escalada a administrador | `precondition` |
| Cross-account sin `ExternalId` | Confused deputy | `validation` |
| Rol sin permissions boundary | Escalada creando roles más privilegiados | `validation` con exención auditable |
| `max_session_duration` de 12 horas | Credenciales robadas válidas todo el día | Default de 1 hora |
| Rol que nadie puede asumir | No falla, simplemente no funciona, y se descubre tarde | `validation` de al menos un origen de confianza |
| Políticas gestionadas huérfanas | Desorden creciente en la cuenta | Políticas propias como inline |
| Nombres colisionando entre proyectos | IAM es global | Convención `<cliente>-<entorno>-<rol>` |

---

## 9. Estructura de archivos

```
modules/iam-role/
├── README.md
├── versions.tf
├── variables.tf
├── locals.tf        # tags + decodificación y normalización del JSON de políticas
├── main.tf          # trust policy, rol, políticas, instance profile
├── outputs.tf
├── examples/
│   ├── minimal/     # rol de servicio para Lambda, una política inline
│   └── complete/    # cross-account con ExternalId, gestionadas + inline, instance profile
└── tests/
    └── defaults.tftest.hcl
```

Un solo `main.tf`: bajo la regla funcional del repositorio, el módulo tiene un único grupo.

---

## 10. Uso desde el repositorio live

```hcl
# 20-security/roles.tf

data "aws_iam_policy_document" "app_permissions" {
  statement {
    sid       = "LeerConfiguracion"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.config.arn}/*"]
  }

  statement {
    sid       = "LeerSecretos"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.db.arn]
  }
}

module "role_app" {
  source = "git::https://github.com/PiConsulting/PI-Modules.git//modules/iam-role?ref=iam-role/v1.0.0"

  name        = "${var.name_prefix}-app-task"
  environment = var.environment
  description = "Rol de las tareas ECS de la aplicacion"

  trusted_services = ["ecs-tasks.amazonaws.com"]

  inline_policies = {
    app = data.aws_iam_policy_document.app_permissions.json
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
  ]

  permissions_boundary_arn = data.aws_iam_policy.platform_boundary.arn

  tags = local.common_tags
}
```

Y el caso cross-account, con la condición obligatoria:

```hcl
module "role_partner" {
  source = "...//modules/iam-role?ref=iam-role/v1.0.0"

  name        = "${var.name_prefix}-partner-readonly"
  environment = var.environment
  description = "Acceso de solo lectura para el partner de analitica"

  trusted_account_ids = ["111122223333"]
  external_id         = var.partner_external_id   # desde Secrets Manager, no en el tfvars

  managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]

  permissions_boundary_arn = data.aws_iam_policy.platform_boundary.arn

  tags = local.common_tags
}
```

El `external_id` no va en un `.tfvars`: es un secreto compartido con el tercero. Sale de
Secrets Manager o de una variable de entorno del pipeline.

---

## 11. Versionado

**Tag:** `iam-role/vMAJOR.MINOR.PATCH`

| Cambio | Bump |
|---|---|
| Cambiar el tipo de `inline_policies` | **MAJOR** |
| Hacer obligatoria una variable que no lo era | **MAJOR** |
| Endurecer una `precondition` | **MAJOR** — un consumidor que hoy pasa el plan mañana no lo pasa |
| Bajar el default de `max_session_duration` | **MAJOR** — cambia el comportamiento sin que lo pidan |
| Añadir OIDC tras campos opcionales | MINOR |
| Añadir `create_instance_profile` u otro flag desactivado por defecto | MINOR |
| Nuevo output | MINOR |
| Mensaje de error más claro | PATCH |

La tercera fila vuelve a ser la contraintuitiva, igual que en `sg`: **endurecer es
incompatible.** Conviene repetirlo en cada spec porque es el error de versionado que más se
cuela.

---

## 12. Checklist antes de producción

**Permisos**

- [ ] Ninguna política con `Action:*` sobre `Resource:*`
- [ ] `iam:PassRole`, si aparece, restringido a ARNs concretos
- [ ] Las políticas gestionadas adjuntas se han leído, no solo copiado
- [ ] Ningún `AdministratorAccess` ni `PowerUserAccess` sin justificación por escrito

**Confianza**

- [ ] Todo rol cross-account tiene `external_id` de entropía suficiente
- [ ] El `external_id` no está en el repositorio: viene de Secrets Manager o del pipeline
- [ ] Los principales de servicio llevan `aws:SourceAccount` donde aplique
- [ ] `max_session_duration` acorde al uso: 1 hora para servicios, más solo si hay motivo

**Gobierno**

- [ ] `permissions_boundary_arn` presente, o `boundary_exempt_reason` que un auditor aceptaría
- [ ] Nombres siguiendo `<cliente>-<entorno>-<rol>`
- [ ] Tags completos
- [ ] IAM Access Analyzer activo en la cuenta y sin hallazgos sobre estos roles

**Operación**

- [ ] Políticas inline por debajo de los 10.240 caracteres agregados
- [ ] `terraform destroy` limpio, sin políticas huérfanas

---

## Estado y siguiente paso

| | |
|---|---|
| Spec | ✅ |
| Implementación | ⬜ |
| Ejemplos | ⬜ |
| Tests | ⬜ |
| Empaquetado validado desde PI-Live | ⬜ |
| Tag `iam-role/v1.0.0` | ⬜ |

**Módulo siguiente:** `kms`. Su decisión de diseño central será la política de clave: el
mismo problema de `iam-role` —recibir un documento de política sin convertirse en un
pass-through— más el statement raíz que no se puede omitir sin quedarse fuera de la propia
clave.