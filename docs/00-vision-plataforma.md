# Plataforma Modular de Infraestructura AWS

**Propuesta técnica y comercial · Repositorio centralizado de módulos Terraform**

Versión 1.0 · Julio 2026

---

## 0. Resumen ejecutivo (para líderes de la consultora)

Hoy cada proyecto cloud de la consultora se construye casi desde cero. El resultado es
predecible: el primer proyecto tarda 8 semanas, el segundo tarda 7, y el décimo sigue
tardando 6. No hay curva de aprendizaje capitalizada porque el conocimiento vive en la
cabeza de las personas y en repos que nadie vuelve a mirar.

Esta propuesta convierte ese conocimiento en un **activo reutilizable**: un catálogo de
módulos Terraform versionados, mantenidos centralmente y consumidos por los repositorios
de cada cliente mediante referencia Git con tag inmutable.

**El cambio en una línea:** pasamos de vender horas de ingeniería a vender una plataforma
probada, y las horas se van a lo que el cliente realmente valora (su negocio), no a
reescribir por décima vez una VPC con subredes bien calculadas.

| Métrica | Hoy | Con la plataforma |
|---|---|---|
| Time-to-first-deploy de un cliente nuevo | 4–8 semanas | 3–5 días |
| Retrabajo entre proyectos | Alto (copy/paste) | Bajo (módulo versionado) |
| Consistencia de seguridad entre clientes | Depende del ingeniero | Garantizada por defecto |
| Coste de corregir un fallo de seguridad | Cliente por cliente | Un fix + bump de versión |
| Onboarding de un ingeniero nuevo | Semanas | Días (docs + ejemplos) |

**Inversión inicial estimada:** 6–8 semanas de un ingeniero senior (o 4 con dos personas)
para llegar a un MVP desplegable en producción. A partir del tercer cliente, la
plataforma se paga sola.

---

## 1. Qué problema real resuelve

### 1.1 Para la consultora

| Problema | Coste actual | Cómo lo resuelve la plataforma |
|---|---|---|
| **Reinvención constante** | 60–70 % del esfuerzo inicial de cada proyecto es infraestructura base ya construida antes | Módulos base listos: VPC, IAM, KMS, ALB, ECS |
| **Calidad no determinista** | La seguridad del entregable depende de quién lo hizo | Los controles vienen embebidos en el módulo, no en la disciplina del ingeniero |
| **Dependencia de personas clave** | Si se va el arquitecto, se va el criterio | El criterio está codificado y documentado |
| **Presupuestos difíciles de estimar** | Cada propuesta es una estimación desde cero | Catálogo con esfuerzo conocido por arquitectura |
| **Margen bajo** | Se factura tiempo, no valor | Se factura una plataforma; el tiempo baja, el margen sube |
| **Escalar el equipo** | Un junior no puede entregar solo | Un junior compone módulos probados y entrega |
| **Corregir un fallo transversal** | Hay que tocar N repos de N clientes | Fix en el módulo + bump de versión coordinado |

### 1.2 Para el cliente final

| Problema del cliente | Cómo lo resuelve |
|---|---|
| "Mi infraestructura la montaron a mano y nadie sabe qué hay" | Todo es código, versionado, revisable y auditable |
| "No sé si estoy cumpliendo buenas prácticas" | Well-Architected aplicado por defecto, con evidencia |
| "Mi factura de AWS crece y no sé por qué" | Tagging obligatorio, Budgets y Cost Anomaly Detection desde el día 1 |
| "Cada cambio es un riesgo" | CI/CD con `plan` revisable y aprobación explícita antes de `apply` |
| "Si me pasa algo, no sé cuánto tardo en recuperarme" | RTO/RPO explícitos, multi-AZ por defecto, backups configurados |
| "Dependo del proveedor que me montó esto" | El cliente recibe el código; los módulos son estándar Terraform, no magia propietaria |
| "No tengo visibilidad de qué está pasando" | Logs, métricas y alarmas de base incluidas |

### 1.3 El argumento comercial en una frase

> *"No le vendemos horas de consultoría. Le entregamos una plataforma que ya pasó por
> producción en otros clientes, adaptada a su negocio, con la seguridad, la observabilidad
> y el control de costes incluidos de fábrica — y el código es suyo."*

---

## 2. Catálogo de arquitecturas (sin WordPress)

Cinco arquitecturas de referencia, todas compuestas a partir del **mismo catálogo de
módulos**. Esto es clave: no son cinco productos distintos, son cinco recetas sobre los
mismos ingredientes.

### A. Contenedores sobre ECS Fargate — *"Plataforma de aplicaciones"*

```
Internet → CloudFront + WAF → ALB (público) → ECS Fargate (subredes privadas)
                                                    ↓
                                         RDS/Aurora (subredes de datos)
                                         ElastiCache · S3 · Secrets Manager
```

- **Para quién:** SaaS, APIs de negocio, backends de aplicaciones web, portales internos.
- **Por qué es la apuesta principal:** cubre la mayoría de cargas empresariales, no obliga
  a reescribir la aplicación (solo a contenerizarla) y es la arquitectura donde más se
  nota el valor de la automatización.
- **Módulos:** VPC, SG, IAM, KMS, ACM, CloudFront, WAF, ALB, ECS Fargate, RDS, Secrets
  Manager, CloudWatch, ECR.

### B. Serverless de eventos y APIs

```
API Gateway / EventBridge → Lambda → DynamoDB / Aurora Serverless v2 → S3
```

- **Para quién:** integraciones, procesamiento asíncrono, back-office, cargas de tráfico
  muy variable, startups con presupuesto ajustado.
- **Ventaja comercial:** coste operativo bajísimo en reposo; excelente para pilotos.
- **Módulos:** VPC (solo si hay VPC-attached), IAM, KMS, S3, Lambda, API Gateway,
  EventBridge, DynamoDB, Secrets Manager, CloudWatch.

### C. Sitio estático + API — *"Frontend moderno"*

```
S3 (privado) ← OAC ← CloudFront + WAF + ACM
                          ↓ /api/*
                    ALB o API Gateway
```

- **Para quién:** SPAs (React/Vue/Angular), sitios corporativos, documentación, landings
  de campaña.
- **Ventaja comercial:** es la venta de entrada más barata y rápida. Time-to-value de días.
- **Módulos:** S3, CloudFront, ACM, WAF, Route 53, IAM (rol de despliegue CI).

### D. Landing Zone y baseline de gobierno multi-cuenta

```
AWS Organizations → OUs → cuentas (security, shared, workloads)
   + SCPs + IAM Identity Center + CloudTrail org-wide
   + GuardDuty · Security Hub · Config · Budgets
```

- **Para quién:** empresas medianas/grandes que ya tienen AWS pero sin gobierno, o que
  van a crecer a varias cuentas.
- **Ventaja comercial:** es el servicio con mejor margen y el que abre la puerta a todo lo
  demás. El cliente que te deja montar su landing zone te deja montar sus workloads.
- **Módulos:** Organizations, SCPs, IAM, KMS, CloudTrail, GuardDuty, Security Hub, Config,
  Budgets, Cost Anomaly Detection.

### E. Plataforma de datos / analítica

```
Ingesta (Kinesis/DMS/S3) → S3 Data Lake (raw/curated/consumed)
   → Glue Catalog → Athena / Redshift Serverless → QuickSight
```

- **Para quién:** clientes con reporting manual en Excel, o que quieren empezar con datos.
- **Módulos:** S3 (con lifecycle y capas), KMS, IAM, Glue, Athena, Lake Formation.

### Cómo se venden

| Arquitectura | Ticket típico | Esfuerzo tras MVP | Prioridad |
|---|---|---|---|
| A. ECS Fargate | Medio-alto | 1–2 semanas | **1** |
| C. Estático + API | Bajo | 2–4 días | **2** (puerta de entrada) |
| D. Landing Zone | Alto | 2–3 semanas | **3** (mayor margen) |
| B. Serverless | Medio | 1–2 semanas | 4 |
| E. Datos | Alto | 3–4 semanas | 5 |

---

## 3. Arquitectura base del MVP

**Decisión: Arquitectura A (ECS Fargate + ALB) en una sola cuenta y una sola región.**

### Por qué esta y no otra

1. **Cobertura.** Los módulos que necesita (VPC, SG, IAM, KMS, S3, ACM, CloudFront, WAF,
   ALB, ECS, RDS, Secrets, CloudWatch) son el 80 % de los módulos que necesitan *todas*
   las demás arquitecturas. Construir el MVP A construye simultáneamente los cimientos de
   B, C, D y E.
2. **Demostrabilidad.** Se puede desplegar una app de ejemplo y enseñarla funcionando en
   una reunión comercial.
3. **Riesgo controlado.** No requiere Organizations ni permisos cross-account, así que se
   puede construir en la cuenta de laboratorio de la consultora sin fricción.

### Alcance del MVP (lo que entra)

```
                        Route 53 (opcional, hosted zone del cliente)
                              │
                        CloudFront + WAF + ACM (us-east-1)
                              │
                    ┌─────────┴─────────┐
                    │   VPC 10.0.0.0/16  │  3 AZs
                    │                    │
   subnets públicas │  ALB (HTTPS 443)   │  ← ACM regional
                    │        │           │
   subnets privadas │  ECS Fargate ×N    │  ← autoscaling por CPU/RPS
                    │        │           │
   subnets de datos │  RDS/Aurora Multi-AZ│ ← KMS, Secrets Manager
                    └────────────────────┘
   Transversal: VPC Flow Logs · CloudWatch Logs+Alarms · GuardDuty
                Budgets · Cost Anomaly Detection · S3 (logs/artefactos)
```

### Fuera de alcance del MVP (fase 2)

- Multi-región y DR activo-activo.
- Multi-cuenta / Organizations.
- Service mesh, EKS.
- Aurora Global Database.
- CI/CD de la *aplicación* (esto es CI/CD de la *infraestructura*).

### Criterio de "MVP terminado"

- [ ] Un cliente ficticio se despliega de cero a producción en < 4 horas de trabajo humano.
- [ ] `terraform destroy` deja la cuenta limpia (sin recursos huérfanos ni costes residuales).
- [ ] Checkov/tfsec pasa sin findings críticos ni altos.
- [ ] El coste mensual en reposo del entorno `dev` está por debajo de un umbral definido y documentado.
- [ ] Un ingeniero que no participó en la construcción despliega el stack siguiendo solo el README.

---

## 4. Módulos priorizados

Priorización por **(a)** cuántas arquitecturas lo usan, **(b)** cuánto bloquea a otros
módulos, **(c)** cuánto dolor evita si está mal hecho.

### Tier 0 — Cimientos (nada funciona sin esto)

| # | Módulo | Por qué es Tier 0 | Esfuerzo |
|---|---|---|---|
| 1 | **vpc** | Todo se despliega dentro. El error más caro de corregir a posteriori (rediseñar CIDRs con carga en producción es una migración, no un cambio) | 5 d |
| 2 | **security-groups** | Superficie de exposición. Un SG mal hecho es una brecha | 2 d |
| 3 | **iam-role** | Todo servicio necesita un rol. Define la postura de menor privilegio | 3 d |
| 4 | **kms** | Cifrado en reposo transversal. Meterlo después obliga a recrear recursos | 2 d |

### Tier 1 — Bloques de aplicación

| # | Módulo | Notas | Esfuerzo |
|---|---|---|---|
| 5 | **s3** | Logs, artefactos, contenido estático. Base de todo | 2 d |
| 6 | **acm** | Bloquea CloudFront y ALB. Validación DNS automatizada | 1 d |
| 7 | **cloudfront** | Edge, caché, TLS, WAF asociado | 3 d |
| 8 | **waf** | Reglas gestionadas + rate limiting. Quick win de seguridad muy visible | 2 d |
| 9 | **alb** | Entrada al cómputo, health checks, listeners, reglas | 3 d |
| 10 | **ecs-fargate** | El corazón del MVP: cluster, service, task def, autoscaling | 5 d |
| 11 | **rds-aurora** | Multi-AZ, cifrado, backups, ventanas de mantenimiento | 4 d |
| 12 | **secrets-manager** | Credenciales sin hardcode, rotación | 2 d |

### Tier 2 — Operación y gobierno

| # | Módulo | Notas | Esfuerzo |
|---|---|---|---|
| 13 | **cloudwatch** | Log groups, retención, métricas, alarmas, dashboard | 3 d |
| 14 | **guardduty** | Detección de amenazas. Casi gratis de implementar | 1 d |
| 15 | **security-hub** | Consolidación de findings, standards CIS/FSBP | 1 d |
| 16 | **budgets** | Budgets + Cost Anomaly Detection + alertas | 2 d |
| 17 | **ci-cd** | Rol OIDC para GitHub Actions, backend S3+DynamoDB, workflows | 4 d |

### Tier 3 — Extensión por arquitectura (post-MVP)

`lambda`, `api-gateway`, `dynamodb`, `route53`,
`ecr`, `elasticache`, `organizations`, `scp`,
`glue-athena`, `transit-gateway`.

### Regla de oro de la priorización

> Nunca se empieza un módulo del Tier N+1 mientras haya un módulo del Tier N sin
> `v1.0.0` etiquetada, documentada y probada en un despliegue real.

---

## 5. Repositorio centralizado de módulos

**Un solo repositorio (monorepo de módulos).** No un repo por módulo.

### Por qué monorepo

- Un solo PR puede cambiar módulo + ejemplos + docs de forma atómica.
- Un solo pipeline de CI cubre todo.
- Descubribilidad: un ingeniero nuevo abre un repo, no treinta.
- El coste de un monorepo (tags globales) se mitiga con tags por módulo (§5.3).

### 5.1 Estructura

```
tf-modules-pi/
├── README.md                        # Catálogo: qué módulo hay, para qué y su estado
├── CONTRIBUTING.md                  # Cómo se propone y aprueba un módulo nuevo
├── CHANGELOG.md                     # Cambios agregados por release
├── .github/
│   └── workflows/
│       ├── validate.yml             # fmt, validate, tflint, checkov, terraform-docs
│       ├── test.yml                 # terratest / terraform test sobre examples/
│       └── release.yml              # Valida el tag y publica notas de release
├── docs/
│   ├── 00-vision-plataforma.md      # Este documento
│   ├── 01-convenciones.md           # Naming, tagging, versionado, estilo
│   ├── 02-arquitecturas/            # Fichas de las arquitecturas de referencia
│   └── modules/                     # Una spec por módulo
│       └── 01-vpc.md
├── modules/
│   ├── vpc/
│   ├── security-groups/
│   ├── iam-role/
│   ├── kms/
│   ├── waf/
│   ├── acm/
│   ├── cloudfront/
│   ├── alb/
│   ├── ecs-fargate/
│   ├── rds-aurora/
│   ├── secrets-manager/
│   ├── s3/
│   ├── cloudwatch/
│   ├── guardduty/
│   ├── security-hub/
│   ├── budgets/
│   └── ci-cd/
├── patterns/                        # Composiciones de módulos = arquitecturas completas
│   ├── web-app-ecs/
│   ├── static-site/
│   └── serverless-api/
└── examples-live/                   # Cómo se ve un repo live real
    └── acme/
```

### 5.2 Anatomía obligatoria de un módulo

```
modules/<nombre>/
├── README.md          # Generado por terraform-docs + secciones manuales
├── versions.tf        # required_version + required_providers (rangos, no pins exactos)
├── variables.tf       # Toda entrada, con description, type y validation
├── locals.tf          # Cálculos derivados, normalización de nombres y tags
├── main.tf            # Los recursos (dividir en <recurso>.tf si supera ~300 líneas)
├── outputs.tf         # Todo lo que otro módulo pueda necesitar
├── examples/
│   ├── minimal/       # El mínimo viable — sirve de test de humo
│   └── complete/      # Todas las features activadas — sirve de test de integración
└── tests/             # terraform test (.tftest.hcl) o terratest
```

**Reglas no negociables:**

| Regla | Motivo |
|---|---|
| El módulo **no** declara bloques `provider` | Los providers se inyectan desde el root. Declararlos rompe `for_each` y aliases |
| El módulo **no** declara `backend` | El backend es responsabilidad del root del repo live |
| `required_version` usa rango (`~> 1.9`), no pin exacto | Un pin exacto en un módulo bloquea a todos sus consumidores |
| Cero valores hardcodeados de cliente, cuenta, región o CIDR | Es lo que hace al módulo reutilizable |
| Toda variable tiene `description` y `type` explícito | El README se genera de ahí |
| Variables con dominio acotado llevan `validation` | Fallar en `plan` es 100× más barato que fallar en `apply` |
| Todo recurso soporta tags de entrada + tags calculados | Trazabilidad de coste y propiedad |
| `examples/minimal` y `examples/complete` deben pasar `plan` en CI | Un ejemplo roto es peor que no tener ejemplo |

### 5.3 Versionado con tags Git

**Formato:** `<módulo>/vMAJOR.MINOR.PATCH`

```
vpc/v1.0.0
vpc/v1.1.0
kms/v1.0.0
```

Esto permite que cada módulo evolucione a su propio ritmo dentro del monorepo. Además se
mantienen tags globales de plataforma (`platform/v2026.07.0`) que representan un conjunto
compatible de módulos — útil para decirle a un cliente "estás en la release de julio".

**Semántica:**

| Cambio | Bump |
|---|---|
| Eliminar o renombrar una variable u output | **MAJOR** |
| Cambio que fuerza recreación de recursos existentes | **MAJOR** |
| Cambiar un `default` por otro con distinto comportamiento | **MAJOR** |
| Añadir variable opcional con default retrocompatible | MINOR |
| Añadir output | MINOR |
| Nuevo recurso opcional detrás de un flag `enable_*` desactivado | MINOR |
| Corrección de bug sin cambio de interfaz | PATCH |
| Documentación, tests, formato | PATCH |

**Regla de consumo:** los repos live **siempre** referencian un tag exacto, nunca `main`
ni una rama.

```hcl
source = "git::https://github.com/benjamin-cloud-pi/PI-Modules.git//modules/vpc?ref=vpc/v1.2.0"
```

**Política de soporte:** se mantienen las dos últimas MAJOR de cada módulo. Al publicar
una MAJOR nueva se escribe una guía de migración en `docs/migrations/`.

---

## 6. Repositorio live por cliente

**Un repositorio por cliente.** Nunca un repo compartido entre clientes: el blast radius
de un error y los permisos de acceso lo hacen inaceptable.

### 6.1 Estructura (Terraform puro, sin Terragrunt)

```
tf-live-acme/
├── README.md                        # Contexto del cliente, contactos, runbook de deploy
├── .github/workflows/
│   ├── plan.yml                     # Se dispara en PR
│   └── apply.yml                    # Se dispara al mergear a main (con environment gate)
├── global/                          # Recursos sin región (IAM, Organizations, Budgets)
│   └── iam/
│       ├── main.tf
│       ├── backend.hcl
│       └── terraform.tfvars
├── us-east-1/
│   ├── _regional.tfvars             # Valores comunes a la región (region, azs)
│   ├── dev/
│   │   ├── _env.tfvars              # Valores comunes al entorno (environment, tags)
│   │   ├── 10-networking/
│   │   │   ├── main.tf              # Consume el módulo vía source Git + ref
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   ├── versions.tf
│   │   │   ├── backend.hcl          # bucket, key, dynamodb_table, region
│   │   │   └── terraform.tfvars     # Valores específicos de esta capa
│   │   ├── 20-security/
│   │   ├── 30-data/
│   │   ├── 40-compute/
│   │   └── 50-edge/
│   ├── stg/
│   └── prod/
└── eu-west-1/
    └── prod/
```

### 6.2 Las tres decisiones de diseño de esta estructura

**a) Prefijos numéricos = orden de dependencia explícito.** Cualquiera ve que
`10-networking` va antes que `40-compute`. El pipeline lo recorre en orden alfabético y
funciona.

**b) Un state por capa, no un state monolítico.** Un `plan` de la capa de cómputo no toca
el state de red. Menos tiempo de plan, menos riesgo, menos bloqueos entre equipos.

**c) Las capas se comunican por `data` sources, no por `remote_state`.** Preferimos
descubrir la VPC por tag (`data "aws_vpc"` con filtro) antes que leer el state de otra
capa. Reduce el acoplamiento y evita que la capa de red tenga que exponer state a todos.
Cuando el acoplamiento es inevitable, se usa `terraform_remote_state` con acceso de solo
lectura al bucket.

### 6.3 Backend

```hcl
# us-east-1/prod/10-networking/backend.hcl
bucket         = "acme-tfstate-us-east-1"
key            = "prod/10-networking/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "acme-tfstate-lock"
encrypt        = true
kms_key_id     = "arn:aws:kms:us-east-1:111122223333:key/xxxxxxxx"
```

```bash
terraform init -backend-config=backend.hcl
terraform plan  -var-file=../_env.tfvars -var-file=../../_regional.tfvars -var-file=terraform.tfvars
```

**Sin workspaces de Terraform para separar entornos.** Los workspaces comparten
configuración y hacen invisible el entorno en el código; separar por carpeta es más
explícito, permite versiones de módulo distintas por entorno (clave para promocionar
cambios de dev → stg → prod) y hace que un `cd` mal hecho no destruya producción.

### 6.4 Promoción de cambios entre entornos

```
dev  → módulo vpc v1.3.0   (se prueba aquí primero)
stg  → módulo vpc v1.2.0   (se sube cuando dev lleva 3 días estable)
prod → módulo vpc v1.2.0   (se sube tras validación en stg)
```

El "deploy" a producción es literalmente un PR que cambia una cadena de versión. Es
revisable, es auditable y es reversible.

---

## 7. Well-Architected aplicado a cada módulo

En vez de tratar el framework como un checklist de auditoría anual, lo convertimos en
requisitos de diseño de módulo.

### 7.1 Traducción pilar → requisito de módulo

| Pilar | Qué exige a TODO módulo |
|---|---|
| **Excelencia operativa** | Todo es código; tags obligatorios (`Owner`, `Environment`, `Project`, `ManagedBy`); outputs suficientes para operar; `prevent_destroy` en recursos con estado; nombres deterministas |
| **Seguridad** | Cifrado en reposo y en tránsito por defecto; menor privilegio (sin `*` en Action ni Resource salvo justificación documentada); nada público salvo `enable_public_*=true` explícito; logging activado; secretos vía Secrets Manager/SSM, nunca en variables |
| **Confiabilidad** | Multi-AZ por defecto (≥2 AZ); health checks; backups con retención configurable; `create_before_destroy` donde aplique; sin dependencias implícitas de una sola AZ |
| **Eficiencia de rendimiento** | Tipos/tamaños parametrizados, nunca fijos; autoscaling disponible como opción; caché donde tenga sentido; sin sobredimensionar por defecto |
| **Optimización de costes** | Defaults económicos (el default nunca es el más caro); retención de logs finita; lifecycle en S3; NAT Gateway configurable (1 vs N); `enable_*` para todo lo que cueste dinero |
| **Sostenibilidad** | Recursos justos, apagado de no-productivos, regiones con energía limpia como recomendación en docs |

### 7.2 Cómo se verifica (no basta con declararlo)

| Mecanismo | Qué valida | Cuándo corre |
|---|---|---|
| `terraform validate` + `tflint` | Sintaxis, tipos, reglas de estilo y de proveedor AWS | Cada PR |
| **Checkov / tfsec / Trivy** | Controles de seguridad y compliance sobre el HCL | Cada PR (bloqueante en críticos/altos) |
| **Infracost** | Impacto de coste del cambio, comentado en el PR | Cada PR |
| **OPA / Conftest** | Políticas propias de la consultora (ej: "todo bucket S3 debe tener `block_public_access`") | Cada PR |
| `terraform test` / Terratest | Que los `examples/` realmente despliegan | Nightly y pre-release |
| **AWS Config + Security Hub** | Deriva y postura en runtime, ya desplegado | Continuo en la cuenta del cliente |

### 7.3 Matriz de responsabilidad módulo vs. root

Regla general: **el módulo hace cumplir lo que no es negociable; el root decide lo que es
específico del negocio.**

| Decisión | Módulo | Root (repo live) |
|---|---|---|
| Cifrado activado | ✅ Impone | — |
| *Qué* clave KMS usar | — | ✅ Decide (o el módulo crea una si no se pasa) |
| Multi-AZ | ✅ Impone mínimo 2 | ✅ Decide si 2 o 3 |
| CIDR de la VPC | — | ✅ Decide |
| Bloqueo de acceso público en S3 | ✅ Impone | — |
| Tamaño de instancia / task | — | ✅ Decide |
| Retención de logs | ✅ Impone un default finito | ✅ Puede ajustar |
| Nombre de los recursos | ✅ Compone según convención | ✅ Aporta `name_prefix` |

---

## 8. Quick Wins incluidos por defecto

Estos son los controles que van **activados de fábrica**. Su valor comercial es enorme:
son cosas que el cliente no pidió, que le costarían semanas conseguir por su cuenta, y que
puedes enseñar en la primera demo.

### 8.1 Seguridad

| Quick win | Módulo | Esfuerzo | Impacto |
|---|---|---|---|
| S3 Block Public Access en cuenta + bucket | s3 / baseline | Trivial | Alto |
| Cifrado en reposo con KMS en todo recurso que lo soporte | transversal | Bajo | Alto |
| TLS 1.2+ mínimo y redirección HTTP→HTTPS | alb / cloudfront | Trivial | Alto |
| EBS encryption by default a nivel de cuenta | baseline | Trivial | Alto |
| IMDSv2 obligatorio | ec2 / asg | Trivial | Alto |
| VPC Flow Logs a CloudWatch o S3 | vpc | Bajo | Alto |
| GuardDuty habilitado | guardduty | Trivial | Muy alto |
| Security Hub + estándar AWS FSBP | security-hub | Trivial | Alto |
| CloudTrail multi-región con validación de integridad | baseline | Bajo | Muy alto |
| WAF con reglas gestionadas + rate limiting | waf | Bajo | Alto |
| Secrets en Secrets Manager, nunca en variables ni en state | secrets | Medio | Muy alto |
| Sin SG con `0.0.0.0/0` en puertos administrativos (22, 3389) | security-groups | Trivial | Muy alto |
| IAM Access Analyzer activo | baseline | Trivial | Medio |

### 8.2 Costes

| Quick win | Esfuerzo | Impacto |
|---|---|---|
| Tagging obligatorio y validado (`CostCenter`, `Project`, `Environment`, `Owner`) | Bajo | Muy alto |
| AWS Budgets con alertas al 50/80/100 % del presupuesto | Trivial | Alto |
| Cost Anomaly Detection con notificación | Trivial | Alto |
| Retención de logs finita (no "Never expire") | Trivial | Alto — el gasto oculto más común |
| S3 Lifecycle: transición a IA/Glacier + expiración de versiones antiguas | Bajo | Alto |
| NAT Gateway único en entornos no productivos | Trivial | Alto (~32 USD/mes por NAT evitado) |
| VPC Endpoints para S3 y DynamoDB (gateway, gratis) | Trivial | Medio-alto |
| Apagado programado de entornos dev/stg fuera de horario | Bajo | Alto |
| Infracost en el PR: el coste se ve *antes* de aprobar | Bajo | Alto |
| Fargate Spot en entornos no productivos | Bajo | Medio |

### 8.3 Observabilidad

| Quick win | Esfuerzo | Impacto |
|---|---|---|
| Log group por servicio con retención explícita y cifrado | Trivial | Alto |
| Alarmas base: CPU, memoria, 5xx, latencia p99, health de target group | Bajo | Muy alto |
| Dashboard de CloudWatch por entorno | Bajo | Alto (muy demostrable) |
| Container Insights en ECS | Trivial | Alto |
| Alarmas compuestas para reducir ruido | Medio | Medio |
| SNS con destino configurable (email, Slack, PagerDuty) | Bajo | Alto |
| X-Ray / ADOT como opción | Medio | Medio |

### 8.4 Operación

| Quick win | Esfuerzo | Impacto |
|---|---|---|
| State remoto en S3 con versionado, cifrado y lock en DynamoDB | Bajo | Muy alto |
| OIDC federado para CI (cero claves de acceso de larga vida) | Bajo | Muy alto |
| `plan` publicado como comentario en el PR | Bajo | Alto |
| `apply` con aprobación manual obligatoria en `prod` | Trivial | Muy alto |
| Detección de deriva nocturna (`plan` programado que alerta si hay cambios) | Bajo | Alto |
| Backups automáticos con AWS Backup y retención por entorno | Bajo | Muy alto |
| Runbooks en el repo, junto al código | Bajo | Alto |

> **Uso comercial:** estas cuatro tablas son, tal cual, la sección "Qué incluye" de la
> propuesta al cliente. Son ~40 controles que el competidor medio no entrega.

---

## 9. Escalabilidad ante picos de tráfico

### 9.1 Escalado por capas

| Capa | Mecanismo | Tiempo de reacción |
|---|---|---|
| **Edge** | CloudFront: absorbe el pico antes de que llegue a tu infraestructura. Con buen ratio de caché, un pico ×10 puede llegar como ×1,5 al origen | Inmediato |
| **Protección** | WAF rate-based rules: descarta el tráfico abusivo antes del ALB | Inmediato |
| **Balanceo** | ALB escala solo, pero *no instantáneamente*: necesita pre-warming coordinado con AWS para picos súbitos extremos | Minutos |
| **Cómputo** | ECS Service Autoscaling — target tracking sobre `ALBRequestCountPerTarget` (mejor señal que CPU) | 1–3 min |
| **Datos** | Aurora read replicas + Auto Scaling de réplicas; RDS Proxy para pooling de conexiones | 5–15 min |
| **Caché** | ElastiCache delante de la BD para lecturas repetidas | Inmediato |
| **Asíncrono** | SQS entre el frontend y el trabajo pesado: el pico se convierte en cola, no en caída | Inmediato |

### 9.2 Los tres errores que hunden un pico

1. **Escalar por CPU.** La CPU es un indicador tardío. Para tráfico web, escala por
   `ALBRequestCountPerTarget`. Cuando la CPU sube, ya llegas tarde.
2. **Olvidar la base de datos.** El cómputo escala en 90 segundos; una réplica de lectura
   tarda minutos. Si el pico es predecible, la BD se escala *antes*.
3. **Warm-up frío.** Un contenedor que tarda 60 s en estar listo (JIT, carga de config,
   conexiones) hace que el autoscaling llegue tarde. Se mide el tiempo real de arranque y
   se ajusta el `cooldown` y el `health_check_grace_period` en consecuencia.

### 9.3 Estrategia según predictibilidad del pico

| Escenario | Estrategia |
|---|---|
| **Predecible** (Black Friday, campaña, inicio de mes) | Scheduled scaling: se sube el `min_capacity` *antes* del evento. Pre-warm de la BD. Coordinación previa con AWS si el pico es extremo |
| **Impredecible pero acotado** | Target tracking con `min_capacity` holgado + step scaling agresivo hacia arriba y conservador hacia abajo |
| **Impredecible y extremo** | Edge caching agresivo + SQS + degradación elegante (modo lectura, respuestas cacheadas) |

### 9.4 Se diseña por números, no por intuición

Todo cliente debe darnos —o estimar con nosotros— estos cinco números antes de dimensionar:

1. RPS medio y RPS pico esperado (y la relación entre ambos).
2. Latencia objetivo (p50 y p99).
3. Ratio lecturas/escrituras.
4. Cacheabilidad del contenido (% de peticiones que CloudFront puede servir).
5. Tiempo de arranque en frío de una instancia de la aplicación.

Sin esos números, cualquier dimensionamiento es adivinar. **Con esos números, el
dimensionamiento es un cálculo — y eso es exactamente lo que diferencia a un arquitecto de
alguien que copia un tutorial.**

### 9.5 Validación

El diseño no se declara escalable: se prueba. Load test (k6/Artillery) contra `stg`
reproduciendo el pico esperado ×1,5, midiendo latencia p99, tasa de error y tiempo de
convergencia del autoscaling. El resultado se documenta y se entrega al cliente.

---

## 10. Flujo de CI/CD para infraestructura

### 10.1 Pipeline del repo de módulos

```
PR abierto
  ├── terraform fmt -check -recursive
  ├── terraform init -backend=false && terraform validate   (por módulo y por ejemplo)
  ├── tflint  (reglas AWS)
  ├── checkov + tfsec        → bloquea si hay severidad CRITICAL/HIGH
  ├── conftest (políticas OPA propias)
  ├── terraform-docs --check → falla si el README está desactualizado
  └── terraform test         → sobre examples/minimal y examples/complete

Merge a main
  └── Tag <módulo>/vX.Y.Z → release automática con notas de cambio
```

### 10.2 Pipeline del repo live

```
PR abierto
  ├── Detecta qué capas cambiaron (paths-filter)
  ├── Por cada capa afectada:
  │     init (backend real, solo lectura) → validate → plan -out=tfplan
  │     ├── checkov sobre el plan JSON
  │     ├── infracost diff → comenta el delta de coste en el PR
  │     └── publica el plan como comentario y lo guarda como artefacto
  └── Requiere: 1 aprobación (dev/stg), 2 aprobaciones (prod)

Merge a main
  └── Job apply, en orden de capa (10 → 20 → 30 → …)
        ├── GitHub Environment con protection rule → aprobación manual en prod
        ├── apply del MISMO tfplan aprobado (no se replanifica)
        └── notificación del resultado a Slack

Nightly (cron)
  └── plan de todas las capas → si hay diff, alerta de deriva
```

### 10.3 Autenticación: OIDC, no claves

Cero `AWS_ACCESS_KEY_ID` en secretos de CI. GitHub Actions asume un rol vía OIDC:

```hcl
# Condición de confianza del rol
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:consultora/tf-live-acme:ref:refs/heads/main"]
}
```

Dos roles por cuenta: `tf-plan` (solo lectura + acceso al state) y `tf-apply` (escritura,
solo asumible desde `main` y tras aprobación del environment).

### 10.4 Reglas del pipeline

| Regla | Motivo |
|---|---|
| El `apply` usa el fichero de plan aprobado, no replanifica | Lo que se revisó es lo que se aplica |
| El plan es un artefacto con caducidad (24 h) | Un plan viejo aplicado es un riesgo |
| `prod` siempre requiere aprobación humana | No negociable |
| Nunca se hace `apply` desde el portátil de nadie a `prod` | Trazabilidad |
| El bucket de state tiene versionado y MFA delete | Recuperación ante desastre del propio state |
| Los logs de CI no imprimen outputs sensibles | `sensitive = true` + masking |

---

## 11. Documentación de cada módulo

Un módulo sin documentación no existe. La documentación es parte de la definición de
"terminado", no una tarea posterior.

### 11.1 README de módulo — estructura obligatoria

```markdown
# <nombre del módulo>

## Qué resuelve            → 2-3 frases, en lenguaje de negocio
## Cuándo usarlo / cuándo no
## Arquitecturas que lo usan
## Diagrama                → ASCII o Mermaid, siempre presente
## Uso mínimo              → bloque HCL copiable que funciona
## Uso completo            → todas las features
## Requisitos              → versiones de TF y providers
## Inputs                  → GENERADO por terraform-docs
## Outputs                 → GENERADO por terraform-docs
## Decisiones de diseño    → por qué es así y no de otra forma
## Lo que este módulo NO hace
## Errores comunes
## Cómo probarlo
## Checklist de producción
## Changelog / migraciones
```

Las secciones `Inputs` y `Outputs` van entre marcadores de `terraform-docs` y se regeneran
en CI. Si el desarrollador cambia una variable y no regenera, el pipeline falla. La
documentación no puede desincronizarse porque el CI no lo permite.

### 11.2 Los tres niveles de documentación

| Nivel | Audiencia | Dónde vive |
|---|---|---|
| **Catálogo** | Comercial, líder de práctica, cliente | `README.md` raíz: tabla de módulos con estado y descripción de una línea |
| **Referencia** | Ingeniero que va a usar el módulo | `modules/*/README.md` |
| **Diseño** | Ingeniero que va a *modificar* el módulo | `docs/modules/*.md` (las specs) + ADRs |

### 11.3 ADRs

Toda decisión estructural se registra en `docs/adr/NNNN-titulo.md`: contexto, opciones
consideradas, decisión, consecuencias. Ejemplos reales que merecen ADR: "Por qué monorepo
de módulos", "Por qué carpetas por entorno y no workspaces", "Por qué el módulo no crea
su propia clave KMS por defecto".

El valor de un ADR se ve a los seis meses, cuando alguien pregunta "¿y por qué esto está
así?" y la respuesta no depende de que siga en la empresa quien lo decidió.

---

## 12. Cómo avanzar: módulo por módulo

### 12.1 Definición de "terminado" para un módulo

Un módulo no se considera terminado hasta que cumple **las nueve**:

- [ ] Código en `modules/<nombre>/` con la anatomía completa
- [ ] `examples/minimal` y `examples/complete` que pasan `terraform plan`
- [ ] Desplegado **de verdad** en la cuenta de laboratorio, y destruido sin residuos
- [ ] `README.md` completo con inputs/outputs generados
- [ ] Spec de diseño en `docs/modules/`
- [ ] CI en verde: fmt, validate, tflint, checkov, conftest, terraform-docs
- [ ] Checklist de producción del módulo revisada
- [ ] Tag `<nombre>/v1.0.0` publicada
- [ ] Consumido desde un repo live de ejemplo, funcionando

### 12.2 Ciclo por módulo (1–2 semanas)

```
Día 1     Spec de diseño: variables, outputs, límites, decisiones. Se revisa ANTES de codificar.
Día 2-4   Implementación + examples
Día 5     Despliegue real en laboratorio, iteración sobre lo que falló
Día 6     Documentación, tests, checklist
Día 7     Revisión por pares, correcciones, tag v1.0.0
```

La fase de spec del día 1 es la que más tiempo ahorra. Discutir una interfaz de variables
en un documento cuesta una hora; cambiarla cuando tres clientes ya la usan cuesta una
migración.

### 12.3 Roadmap de 12 semanas hasta el primer cliente

| Semana | Entregable | Hito |
|---|---|---|
| 1 | Convenciones + CI del repo de módulos + **VPC** | Repo operativo, primer módulo taggeado |
| 2 | Security Groups + IAM Roles | Cimientos de seguridad |
| 3 | KMS + S3 | Cifrado y almacenamiento |
| 4 | ACM + CloudFront | Capa edge |
| 5 | WAF + ALB | Protección y balanceo |
| 6–7 | **ECS Fargate** | El módulo más complejo. Punto de mayor riesgo del plan |
| 8 | RDS/Aurora + Secrets Manager | Capa de datos |
| 9 | CloudWatch + GuardDuty + Security Hub | Observabilidad y seguridad continua |
| 10 | Budgets + Cost Anomaly + CI/CD | FinOps y automatización |
| 11 | **Pattern `web-app-ecs`** completo end-to-end | La arquitectura A montada de módulos |
| 12 | Repo live de referencia + demo + material comercial | **Listo para vender** |

### 12.4 Principios de ejecución

| Principio | Qué significa en la práctica |
|---|---|
| **Un módulo a la vez** | No se abre el siguiente hasta cerrar el anterior con tag. Cinco módulos al 80 % valen cero |
| **Cada módulo se despliega de verdad** | Un módulo que solo pasó `plan` no está probado. `apply` y `destroy` reales |
| **El primer cliente es el laboratorio** | Se despliega un cliente ficticio completo antes de vender |
| **La documentación se escribe con el código** | No al final. Al final no se escribe |
| **v1.0.0 es un compromiso** | A partir de ese tag, cualquier cambio incompatible cuesta una MAJOR y una guía de migración |
| **Resistir la tentación de la abstracción prematura** | Un módulo que intenta cubrir casos que aún no existen es un módulo imposible de mantener. Se generaliza cuando aparece el segundo caso real, no antes |

### 12.5 Riesgos del plan y mitigación

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| Sobre-ingeniería del módulo VPC (querer cubrir Transit Gateway, IPv6, multi-región desde el día 1) | **Alta** | Alcance cerrado por escrito antes de codificar. Lo demás va a la lista de "cuando aparezca el caso" |
| ECS Fargate se lleva 3 semanas en vez de 2 | Media | Es el riesgo conocido. Se reserva colchón en el plan |
| Cambios de interfaz tardíos que rompen módulos ya taggeados | Media | La spec del día 1; revisión de la interfaz por un segundo par de ojos |
| El proyecto muere por falta de un cliente real que lo justifique | **Alta** | Vender la arquitectura C (estático + API) en la semana 6, con lo que ya esté listo. Un cliente pagando sostiene la inversión |
| Los módulos se llenan de casos específicos de un cliente | Media | Los casos específicos van al repo live del cliente, jamás al módulo. Regla estricta |

---

## Anexo A. Convenciones transversales

### Naming

```
<prefijo-cliente>-<entorno>-<componente>[-<sufijo>]

acme-prod-vpc
acme-prod-alb-public
acme-dev-ecs-api
```

Se construye siempre en `locals` a partir de variables, jamás se escribe literal.

### Tags obligatorios

| Tag | Origen | Ejemplo |
|---|---|---|
| `Project` | variable | `acme-plataforma` |
| `Environment` | variable, validada | `prod` |
| `Owner` | variable | `equipo-plataforma@acme.com` |
| `CostCenter` | variable | `CC-1042` |
| `ManagedBy` | fijo en el módulo | `terraform` |
| `Module` | fijo en el módulo | `vpc` |
| `Repository` | variable | `github.com/consultora/tf-live-acme` |

Se aplican vía `default_tags` en el provider (root) **más** tags de recurso en el módulo.

### Entornos

`dev` · `stg` · `prod` — validados con `validation` en la variable `environment`.
Nada de `test`, `qa2`, `preprod-nuevo`. La disciplina de nombres es la que hace posible la
automatización.

---

## Anexo B. Cómo se usa este documento comercialmente

| Sección | Uso |
|---|---|
| §0 Resumen ejecutivo | Slide 1–2 de la propuesta al cliente / al comité interno |
| §1 Problema | Discovery: se convierte en preguntas para el cliente |
| §2 Catálogo | Menú de servicios de la consultora |
| §8 Quick Wins | Sección "Qué incluye" de la propuesta. **La más vendedora** |
| §9 Escalabilidad | Conversación técnica con el CTO del cliente |
| §10 CI/CD | Responde a "¿cómo garantizan que no rompen nada?" |
| §12.3 Roadmap | Plan de proyecto interno |

---

**Siguiente paso:** módulo 1 — VPC. Spec en
[`docs/modules/01-vpc.md`](modules/01-vpc.md), implementación en
[`modules/vpc/`](../modules/vpc/).
