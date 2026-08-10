<!-- >>> Copiar a `modules/iam-role/README.md` en PI-Modules <<< -->

# iam-role

Rol de IAM con política de confianza construida, límite de permisos obligatorio y
validaciones que rechazan los patrones de escalada de privilegios más comunes.

> **Estado:** pendiente de `v1.0.0` · **Spec de diseño:** [`docs/modules/03-iam-role.md`](../../docs/modules/03-iam-role.md)

---

## Qué resuelve

IAM es donde una arquitectura bien diseñada se echa a perder en silencio. Un security
group mal puesto se ve en un diagrama; una política con `Action: "*"` sobre
`Resource: "*"` no se ve en ningún sitio y concede acceso total a la cuenta.

El módulo convierte en errores de `plan` los cuatro fallos que se repiten siempre:

1. **`*:*` por comodidad** — "lo abrimos mientras depuramos" y queda seis meses
2. **Confianza cross-account sin `ExternalId`** — el *confused deputy*: cualquiera de la
   cuenta de confianza puede asumir el rol, no solo el sistema con el que acordaste el acceso
3. **`iam:PassRole` sin acotar** — el vector de escalada más común de AWS: si puedo pasar
   cualquier rol a un servicio, puedo pasarle el de administrador y ejecutar código con él
4. **Roles sin permissions boundary** — un rol que puede crear roles puede crear uno más
   privilegiado que él mismo

**Es un módulo de disciplina, no de ahorro de tipeo.** No ahorra líneas frente a escribir
`aws_iam_role` a mano; lo que aporta son las validaciones que no se pueden apagar.

## Cuándo usarlo

| Úsalo cuando | No lo uses cuando |
|---|---|
| Cualquier servicio de AWS necesita permisos | El rol ya lo crea otro módulo (`vpc` crea el suyo para flow logs) |
| Das acceso a una cuenta de terceros | Necesitas un usuario IAM — con Identity Center casi nunca es la respuesta |
| Quieres que una revisión detecte políticas peligrosas antes del apply | Necesitas una política gestionada reutilizable entre roles → módulo `iam-policy` |

## Arquitecturas que lo usan

Todas, y con más invocaciones que ningún otro módulo del catálogo: un stack de ECS Fargate
necesita fácilmente cinco o seis roles.

| Consumidor | Rol típico |
|---|---|
| `ecs-fargate` | Task execution role, task role |
| `lambda` | Execution role |
| `ec2` / `asg` | Instance role + instance profile |
| `rds-aurora` | Monitoring role, exportación a S3 |
| `ci-cd` | Roles de plan y apply (con OIDC, que llega en v1.1) |

Depende de: nada. Es un módulo hoja.

---

## Uso mínimo

```hcl
data "aws_iam_policy_document" "app" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${module.bucket.arn}/*"]
  }
}

module "role_app" {
  source = "git::https://github.com/PiConsulting/PI-Modules.git//modules/iam-role?ref=iam-role/v1.0.0"

  name        = "acme-prod-app-task"
  environment = "prod"
  description = "Rol de las tareas ECS de la aplicacion"

  trusted_services = ["ecs-tasks.amazonaws.com"]

  inline_policies = {
    app = data.aws_iam_policy_document.app.json
  }

  permissions_boundary_arn = data.aws_iam_policy.platform_boundary.arn

  tags = local.common_tags
}
```

## Uso completo

Ver [`examples/complete`](examples/complete/main.tf): política de boundary, rol de
servicio, rol cross-account con `ExternalId` y rol de EC2 con instance profile.

---

## Decisiones de diseño

| Decisión | Por qué |
|---|---|
| **`inline_policies` recibe el `.json`, no statements modelados** | Modelar `effect`/`actions`/`resources`/`conditions` como variables es reimplementar el esquema de IAM en la interfaz del módulo. Cada hueco es una limitación; cada hueco tapado es superficie. Y no añade seguridad: el `aws_iam_policy_document` del consumidor ya valida en plan |
| **El módulo inspecciona el JSON y lo rechaza si viola la política** | Ahí sí aporta: imponer lo que no es negociable. Es lo que un pass-through no hace |
| **`name`, no `name_prefix`** — al revés que `sg` | En IAM no existe el `DependencyViolation` que allí obligaba a `create_before_destroy`. Y los nombres de rol aparecen en políticas de confianza escritas en **otras cuentas**: un sufijo aleatorio los vuelve inmanejables |
| **`ExternalId` obligatorio en cross-account** | Sin condición, cualquiera de la cuenta de confianza con `sts:AssumeRole` puede asumir el rol. Es el fallo que llevó a AWS a inventar el ExternalId |
| **Boundary obligatorio, con exención escrita** | Exigirlo sin escape impediría usar el módulo a cualquier cliente que aún no tenga un boundary desplegado, que son todos el primer día. La excepción se permite; que no quede escrita, no |
| **Políticas propias como inline, no gestionadas** | Se borran con el rol. No quedan políticas huérfanas acumulándose, que es uno de los desórdenes clásicos de IAM |
| **`max_session_duration` de 1 hora por defecto** | AWS permite 12. Un default no debe ser nunca el máximo: credenciales robadas con 12 horas de validez son 12 horas de acceso |
| **Validaciones en `precondition`, no en `validation`** | Necesitan `jsondecode` y normalización, que viven en `locals`, y un bloque `validation` solo puede mirar variables. Siguen fallando en `plan` |
| **`aws_partition` en lugar de `"aws"` literal** | En GovCloud es `aws-us-gov` y en China `aws-cn`. Un ARN con la partición equivocada falla en apply |

## Lo que este módulo NO hace

- **No decide qué permisos necesita tu aplicación.** Es conocimiento del negocio.
- **No crea la política de boundary.** Recibe un ARN. → equipo de seguridad o `iam-policy`
- **No crea políticas gestionadas reutilizables.** → `iam-policy`, cuando exista el caso
- **No crea usuarios, grupos ni claves de acceso.** Con Identity Center casi nunca es la respuesta
- **No soporta OIDC, SAML ni IRSA de EKS.** Fuera de v1; OIDC llega con `ci-cd`
- **No incluye atajos curados** tipo `enable_ssm_access`. Se añadirán cuando dos consumidores reales pidan el mismo

## Errores comunes que evita

| Error | Consecuencia | Cómo lo evita |
|---|---|---|
| `Action:*` sobre `Resource:*` | Acceso total a la cuenta | `precondition` |
| `iam:PassRole` sin acotar | Escalada a administrador | `precondition` |
| `sts:AssumeRole` sobre `*` | Pivotar a cualquier rol de la cuenta | `precondition` |
| Cross-account sin `ExternalId` | Confused deputy | `validation` |
| Rol sin permissions boundary | Escalada creando roles más privilegiados | `validation` con exención auditable |
| Sesiones de 12 horas | Credenciales robadas válidas todo el día | Default de 1 hora |
| Rol que nadie puede asumir | No falla: se crea y no sirve, y se descubre tarde | `validation` de al menos un origen de confianza |
| Políticas gestionadas huérfanas | Desorden creciente en la cuenta | Políticas propias como inline |
| Nombres colisionando entre proyectos | IAM es global | Convención `<cliente>-<entorno>-<rol>` |

## Limitaciones conocidas

**10.240 caracteres para el conjunto de políticas inline de un rol.** Es un límite de AWS.
Con políticas grandes hay que pasar a `managed_policy_arns` y crear la política fuera del
módulo.

**El `external_id` aparece en claro en el plan y en el output `assume_role_policy_json`.**
Es deliberado: es un nonce anti-confused-deputy, no una credencial, y marcarlo `sensitive`
impediría auditar la política de confianza desde un PR. Aun así **no lo pongas en un
`.tfvars`**: sale de Secrets Manager o de una variable del pipeline.

**Los tests con `mock_provider` no pueden afirmar sobre la política de confianza
generada,** porque `aws_iam_policy_document` también queda mockeado. Esa verificación se
hace en el despliegue de laboratorio, mirando el rol real.

**Las validaciones inspeccionan el JSON, no evalúan permisos efectivos.** Una política que
concede `s3:*` sobre un bucket concreto pasa, y debe pasar. El módulo detecta patrones
peligrosos, no sustituye a IAM Access Analyzer.

---

## Cómo probarlo

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test          # con mock_provider: sin credenciales ni coste
tflint --recursive
```

**IAM es gratuito**, así que este módulo se puede desplegar de verdad sin coste — y
conviene, porque **AWS valida las políticas en el servidor**: un `s3:GetObjectt` con typo
pasa el plan y lo rechaza el apply. Los nombres de acción, los formatos de ARN y las claves
de condición solo se verifican contra la API.

```bash
cd examples/complete
terraform init && terraform apply
# verificar en la consola: trust policy con ExternalId, boundary adjunto
terraform destroy
```

## Checklist antes de producción

**Permisos**

- [ ] Ninguna política con `Action:*` sobre `Resource:*`
- [ ] `iam:PassRole`, si aparece, restringido a ARNs concretos
- [ ] Las políticas gestionadas adjuntas se han leído, no solo copiado
- [ ] Ningún `AdministratorAccess` ni `PowerUserAccess` sin justificación escrita

**Confianza**

- [ ] Todo rol cross-account tiene `external_id` de entropía suficiente
- [ ] El `external_id` no está en el repositorio
- [ ] Los principales de servicio llevan `trusted_source_account` donde el servicio lo soporte
- [ ] `max_session_duration` acorde al uso: 1 hora para servicios

**Gobierno**

- [ ] `permissions_boundary_arn` presente, o `boundary_exempt_reason` que un auditor aceptaría
- [ ] Nombres siguiendo `<cliente>-<entorno>-<rol>`
- [ ] Tags completos
- [ ] IAM Access Analyzer activo y sin hallazgos sobre estos roles

**Operación**

- [ ] Políticas inline por debajo de los 10.240 caracteres agregados
- [ ] `terraform destroy` limpio, sin políticas huérfanas

---

## Requisitos

| Nombre | Versión |
|---|---|
| terraform | ~> 1.9 |
| aws | >= 6.0, < 7.0 |

## Inputs

<!-- BEGIN_TF_DOCS -->
<!-- Generado por terraform-docs en CI. No editar a mano.
     Regenerar con: terraform-docs -c .terraform-docs.yml modules/iam-role -->
<!-- END_TF_DOCS -->

## Outputs principales

| Output | Consumido por |
|---|---|
| `arn` | ECS como `task_role_arn`, Lambda como `role`, RDS como `monitoring_role_arn` |
| `name` | Políticas de confianza escritas en otras cuentas, runbooks |
| `unique_id` | Condiciones `aws:userid`, que sobreviven a un renombrado |
| `instance_profile_arn` | Módulos de EC2 y autoescalado |
| `assume_role_policy_json` | Auditoría: revisar quién puede asumir el rol desde un PR |
| `has_permissions_boundary` | Políticas automatizadas que verifican la postura |
| `boundary_exempt_reason` | El campo que revisa una auditoría cuando no hay boundary |

---

## Versionado

Tags: `iam-role/vMAJOR.MINOR.PATCH`

| Cambio | Bump |
|---|---|
| Cambiar el tipo de `inline_policies` | MAJOR |
| Hacer obligatoria una variable que no lo era | MAJOR |
| **Endurecer una `precondition`** | **MAJOR** — un consumidor que hoy pasa el plan mañana no lo pasa |
| Bajar el default de `max_session_duration` | MAJOR |
| Añadir OIDC tras campos opcionales | MINOR |
| Nuevo output | MINOR |
| Mensaje de error más claro | PATCH |

## Changelog

### v1.0.0

- Release inicial: política de confianza para servicios y cuentas con `ExternalId`
  obligatorio, políticas inline desde `aws_iam_policy_document`, boundary obligatorio con
  exención documentada, tres preconditions contra patrones de escalada, e instance profile
  opcional.