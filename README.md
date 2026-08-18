# tf-modules-pi

Repositorio centralizado de módulos Terraform para AWS. Módulos genéricos, versionados por
tag Git y consumidos por los repositorios live de cada cliente.


---

## Qué es esto

Un catálogo de bloques de infraestructura probados, con seguridad, observabilidad y
control de costes incluidos por defecto. Los repos de cliente componen estos bloques; no
los reescriben.

```hcl
module "vpc" {
  source = "git::https://github.com/benjamin-cloud-pi/PI-Modules.git//modules/vpc?ref=vpc/v1.0.0"
  # ...
}
```

## Catálogo

| Módulo | Estado | Qué resuelve |
|---|---|---|
| [`vpc`](modules/vpc/) | 🟢 **v1.0.0** | Red base multi-AZ de tres capas, NAT configurable, endpoints y flow logs |
| [`sg`](modules/sg) | 🟢 **v1.0.0** | Reglas entre capas sin exposición accidental |
| [`iam-role`](modules/iam-role)| 🟢 **v1.0.0**  | Roles de menor privilegio con confianza acotada |
| [`kms`](modules/kms) | 🟢 **v1.0.0**  | Claves gestionadas con rotación y políticas |
| `s3` | ⚪ planificado | Buckets privados, cifrados, con lifecycle |
| `acm` | ⚪ planificado | Certificados con validación DNS automatizada |
| `cloudfront` | ⚪ planificado | Distribución de edge con OAC y WAF |
| `waf` | ⚪ planificado | Reglas gestionadas y rate limiting |
| `alb` | ⚪ planificado | Balanceo con health checks y TLS moderno |
| `ecs-fargate` | ⚪ planificado | Servicios de contenedores con autoscaling |
| `rds-aurora` | ⚪ planificado | Bases de datos multi-AZ cifradas con backups |
| `secrets-manager` | ⚪ planificado | Credenciales sin hardcode, con rotación |
| `cloudwatch` | ⚪ planificado | Logs, métricas, alarmas y dashboards |
| `guardduty` | ⚪ planificado | Detección de amenazas |
| `security-hub` | ⚪ planificado | Consolidación de hallazgos, CIS/FSBP |
| `budgets` | ⚪ planificado | Presupuestos y detección de anomalías de coste |
| `ci-cd` | ⚪ planificado | OIDC, backend de state y workflows |

Estados: 🟢 estable · 🟡 en desarrollo · ⚪ planificado

## Arquitecturas de referencia

| # | Arquitectura | Módulos |
|---|---|---|
| A | ECS Fargate + ALB | vpc, sg, iam, kms, acm, cloudfront, waf, alb, ecs, rds, secrets, cloudwatch |
| B | Serverless de eventos y APIs | vpc*, iam, kms, s3, lambda, apigw, dynamodb, secrets |
| C | Sitio estático + API | s3, cloudfront, acm, waf, route53 |
| D | Landing Zone multi-cuenta | organizations, scp, iam, kms, cloudtrail, guardduty, securityhub, budgets |
| E | Plataforma de datos | s3, kms, iam, glue, athena |



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

Tags por módulo: `<nombre>/vMAJOR.MINOR.PATCH`

```
vpc/v1.0.0
kms/v1.0.0
```

Los tags de plataforma (`platform/v2026.07.0`) agrupan un conjunto compatible de módulos.

## Empezar

```bash
# Validación estática de un módulo
cd modules/vpc
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test

# Probarlo de verdad
cd examples/complete
terraform init && terraform apply
terraform destroy
```


