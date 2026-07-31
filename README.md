# tf-modules-pi

Repositorio centralizado de módulos Terraform para AWS. Módulos genéricos, versionados por
tag Git y consumidos por los repositorios live de cada cliente.

📄 **[Propuesta técnica y comercial completa →](docs/00-vision-plataforma.md)**

---

## Qué es esto

Un catálogo de bloques de infraestructura probados, con seguridad, observabilidad y
control de costes incluidos por defecto. Los repos de cliente componen estos bloques; no
los reescriben.

```hcl
module "vpc" {
  source = "git::https://github.com/consultora/tf-modules-pi.git//modules/networking/vpc?ref=networking/vpc/v1.0.0"
  # ...
}
```

## Catálogo

| Módulo | Estado | Qué resuelve |
|---|---|---|
| [`networking/vpc`](modules/networking/vpc/) | 🟢 **v1.0.0** | Red base multi-AZ de tres capas, NAT configurable, endpoints y flow logs |
| `security/security-groups` | ⚪ siguiente | Reglas entre capas sin exposición accidental |
| `security/iam-role` | ⚪ planificado | Roles de menor privilegio con confianza acotada |
| `security/kms` | ⚪ planificado | Claves gestionadas con rotación y políticas |
| `storage/s3` | ⚪ planificado | Buckets privados, cifrados, con lifecycle |
| `networking/acm` | ⚪ planificado | Certificados con validación DNS automatizada |
| `networking/cloudfront` | ⚪ planificado | Distribución de edge con OAC y WAF |
| `security/waf` | ⚪ planificado | Reglas gestionadas y rate limiting |
| `compute/alb` | ⚪ planificado | Balanceo con health checks y TLS moderno |
| `compute/ecs-fargate` | ⚪ planificado | Servicios de contenedores con autoscaling |
| `data/rds-aurora` | ⚪ planificado | Bases de datos multi-AZ cifradas con backups |
| `security/secrets-manager` | ⚪ planificado | Credenciales sin hardcode, con rotación |
| `observability/cloudwatch` | ⚪ planificado | Logs, métricas, alarmas y dashboards |
| `security/guardduty` | ⚪ planificado | Detección de amenazas |
| `security/security-hub` | ⚪ planificado | Consolidación de hallazgos, CIS/FSBP |
| `finops/budgets` | ⚪ planificado | Presupuestos y detección de anomalías de coste |
| `platform/ci-cd` | ⚪ planificado | OIDC, backend de state y workflows |

Estados: 🟢 estable · 🟡 en desarrollo · ⚪ planificado

## Arquitecturas de referencia

| # | Arquitectura | Módulos |
|---|---|---|
| A | ECS Fargate + ALB | vpc, sg, iam, kms, acm, cloudfront, waf, alb, ecs, rds, secrets, cloudwatch |
| B | Serverless de eventos y APIs | vpc*, iam, kms, s3, lambda, apigw, dynamodb, secrets |
| C | Sitio estático + API | s3, cloudfront, acm, waf, route53 |
| D | Landing Zone multi-cuenta | organizations, scp, iam, kms, cloudtrail, guardduty, securityhub, budgets |
| E | Plataforma de datos | s3, kms, iam, glue, athena |

Detalle en [docs/00-vision-plataforma.md §2](docs/00-vision-plataforma.md).

## Estructura del repositorio

```
├── docs/
│   ├── 00-vision-plataforma.md      # Propuesta técnica y comercial
│   └── modules/                     # Una spec de diseño por módulo
├── modules/<dominio>/<nombre>/      # Los módulos
├── patterns/                        # Composiciones = arquitecturas completas
└── examples-live/                   # Plantilla de repo live por cliente
```

## Reglas del repositorio

| Regla | Motivo |
|---|---|
| Ningún módulo declara `provider` ni `backend` | Rompe `for_each`, aliases y decisiones del root |
| Cero valores de cliente, cuenta, región o CIDR incrustados | Es lo que hace al módulo reutilizable |
| Toda variable con `description`, `type` y `validation` donde aplique | Fallar en `plan` es 100× más barato que en `apply` |
| Los repos live referencian **tags**, nunca ramas | Un plan debe ser reproducible mañana |
| Un módulo no es "terminado" hasta desplegarse de verdad y destruirse sin residuos | Un `plan` en verde no prueba nada |
| Los casos específicos de un cliente van al repo del cliente, jamás al módulo | Es la forma en que los módulos genéricos dejan de serlo |

## Versionado

Tags por módulo: `<dominio>/<nombre>/vMAJOR.MINOR.PATCH`

```
networking/vpc/v1.0.0
security/kms/v1.0.0
```

Los tags de plataforma (`platform/v2026.07.0`) agrupan un conjunto compatible de módulos.

## Empezar

```bash
# Validación estática de un módulo
cd modules/networking/vpc
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test

# Probarlo de verdad
cd examples/complete
terraform init && terraform apply
terraform destroy
```

## Roadmap

12 semanas hasta el primer cliente. Detalle en
[docs/00-vision-plataforma.md §12.3](docs/00-vision-plataforma.md).
