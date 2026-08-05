# Plataforma Modular de Infraestructura AWS

**Arquitectura de Referencia y Registro Centralizado de Módulos Terraform**

---

## 0. Resumen Ejecutivo

Hoy, cada nuevo proyecto cloud o entorno en la organización se construye casi desde cero
o mediante la copia de configuraciones anteriores. El resultado es que no hay una curva
de aprendizaje capitalizada; el conocimiento queda aislado en repositorios específicos y
es difícil garantizar estándares transversales de seguridad y costos.

Esta arquitectura convierte la infraestructura en un activo reutilizable: un catálogo de
módulos Terraform versionados, mantenidos centralmente por el equipo de Plataforma y
consumidos por los repositorios de cada proyecto mediante referencias Git con tags
inmutables.

**El objetivo central:** Pasar de operaciones manuales y fragmentadas a una plataforma
estandarizada. El esfuerzo de ingeniería se concentra en aportar valor al producto, no en
reescribir la configuración de red y cómputo base para cada nuevo despliegue.

| Métrica | Estado Actual | Con la Plataforma Modular |
|---|---|---|
| Time-to-first-deploy | Semanas (diseño y construcción manual) | Días (composición de módulos) |
| Retrabajo entre proyectos | Alto (copy/paste y adaptación) | Bajo (módulo central versionado) |
| Postura de Seguridad | Depende del ingeniero a cargo | Estandarizada y garantizada por defecto |
| Corrección de vulnerabilidades | Reparación manual repositorio por repositorio | Fix en el módulo base + actualización de versión |
| Onboarding técnico | Lento (arquitecturas ad-hoc) | Rápido (documentación y ejemplos estandarizados) |

---

## 1. Desafíos Estructurales y la Solución

### 1.1 Problemas Operativos Resueltos

| Desafío Actual | Cómo lo resuelve la Plataforma |
|---|---|
| Reinvención constante | 60–70 % del esfuerzo de un proyecto nuevo es infraestructura base. La plataforma provee bloques listos: VPC, IAM, KMS, ALB, ECS. |
| Calidad no determinista | Los controles de seguridad y arquitectura vienen embebidos en el módulo, reduciendo el error humano. |
| Gobernanza de costos | Etiquetado (tagging) obligatorio, retención de logs finita y optimizaciones de red desde el despliegue inicial. |
| Gestión del cambio | Integración continua (CI/CD) con planes (`terraform plan`) revisables y aprobación explícita antes de aplicar. |
| Falta de visibilidad | Dashboards, alarmas, logs centrales y observabilidad base incluidos en el despliegue estándar. |
| Recuperación y Resiliencia | Despliegues Multi-AZ por defecto, backups automatizados y configuraciones orientadas a RTO/RPO definidos. |

### 1.2 La Propuesta de Valor Técnico

> "Entregamos una plataforma de infraestructura probada, escalable y auditable, con la
> seguridad, la observabilidad y el control de costos embebidos por defecto. Todo
> definido como código, versionado y listo para ser consumido por los equipos de
> producto."

---

## 2. Catálogo de Arquitecturas de Referencia

Cinco arquitecturas de referencia compuestas a partir del mismo catálogo de módulos. No
son productos distintos, son diferentes patrones de composición utilizando los mismos
componentes base.

### A. Contenedores sobre ECS Fargate — "Plataforma de Aplicaciones"

```
Internet → CloudFront + WAF → ALB (público) → ECS Fargate (subredes privadas)
                                                ↓
                                         RDS/Aurora (subredes de datos)
                                         ElastiCache · S3 · Secrets Manager
```

- **Casos de uso:** APIs core, backends de microservicios, portales web.
- **Fundamento:** Cubre la mayoría de cargas empresariales modernas sin gestionar
  servidores subyacentes. Es el patrón donde más se capitaliza la automatización.
- **Módulos Core:** VPC, SG, IAM, KMS, ACM, CloudFront, WAF, ALB, ECS Fargate, RDS,
  Secrets Manager.

### B. Serverless Asíncrono y APIs orientadas a eventos

```
API Gateway / EventBridge → Lambda → DynamoDB / Aurora Serverless v2 → S3
```

- **Casos de uso:** Integraciones, procesamiento en background, cargas de tráfico con
  picos muy marcados o impredecibles.
- **Fundamento:** Costo operativo cercano a cero en reposo; escala instantáneamente.
- **Módulos Core:** IAM, KMS, S3, Lambda, API Gateway, EventBridge, DynamoDB.

### C. Frontend Moderno — "Sitio estático + API"

```
S3 (privado) ← OAC ← CloudFront + WAF + ACM
                         ↓ /api/*
                   ALB o API Gateway
```

- **Casos de uso:** Single Page Applications (React/Vue/Angular), documentación,
  portales estáticos.
- **Fundamento:** Despliegue extremadamente rápido, seguro en el edge y de muy bajo
  costo.
- **Módulos Core:** S3, CloudFront, ACM, WAF, Route 53.

### D. Landing Zone y Gobierno Multi-cuenta

```
AWS Organizations → OUs → Cuentas (Security, Shared, Workloads)
   + SCPs + IAM Identity Center + CloudTrail
   + GuardDuty · Security Hub · Config
```

- **Casos de uso:** Aislamiento de entornos, separación de facturación y límites de
  seguridad estrictos (Blast Radius).
- **Fundamento:** Base indispensable para escalar a múltiples equipos operando en AWS de
  forma simultánea.

### E. Plataforma de Datos y Analítica

```
Ingesta (Kinesis/S3) → S3 Data Lake (Raw/Curated)
   → Glue Catalog → Athena / Redshift Serverless → BI
```

- **Casos de uso:** Pipelines de datos, reporting, preparación para modelos de Machine
  Learning (MLOps).
- **Módulos Core:** S3 (con políticas de ciclo de vida), KMS, IAM, Glue, Athena.

---

## 3. Arquitectura del MVP Inicial

**Decisión de diseño:** Implementar el Patrón A (ECS Fargate + ALB) en un entorno de
validación.

### Justificación

- **Cobertura de componentes:** Los módulos necesarios (VPC, ALB, ECS, RDS, etc.)
  representan el 80% de las dependencias transversales del resto de arquitecturas.
  Construir el Patrón A sienta las bases del resto.
- **Validación End-to-End:** Permite desplegar un microservicio real y validar métricas,
  logs y balanceo de carga.

### Alcance del MVP

```
                        CloudFront + WAF + ACM (Edge)
                              │
                    ┌─────────┴─────────┐
                    │   VPC 10.0.0.0/16 │  3 AZs
                    │                   │
   subnets públicas │  ALB (HTTPS 443)  │  ← ACM regional
                    │        │          │
   subnets privadas │  ECS Fargate ×N   │  ← Autoscaling
                    │        │          │
   subnets de datos │  RDS Multi-AZ     │  ← KMS, Secrets Manager
                    └───────────────────┘
   Transversal: VPC Flow Logs · CloudWatch · S3 Logs · Budgets
```

### Criterios de Éxito del MVP

- Un servicio funcional se despliega mediante la plataforma en menos de una jornada de
  trabajo.
- La ejecución de `terraform destroy` elimina todos los recursos sin dejar estado
  residual.
- El pipeline de análisis estático (Checkov/TFLint) aprueba el código sin
  vulnerabilidades críticas.
- Cualquier ingeniero del equipo puede desplegar el stack basándose únicamente en el
  README.md.

---

## 4. Repositorio Centralizado (Module Registry)

Se adopta una estructura de Monorepo para los módulos base. Esto unifica el pipeline de
validación, asegura versiones consistentes y facilita la mantenibilidad.

### 4.1 Estructura del Repositorio

```
PI-Modules/
├── README.md                # Catálogo de módulos disponibles
├── .github/workflows/
│   ├── validate.yml         # Linter, seguridad y formato
│   └── test.yml             # Pruebas de integración
├── docs/                    # Decisiones de arquitectura (ADRs)
├── modules/                 # Código fuente de los módulos
│   ├── vpc/
│   ├── ecs-fargate/
│   └── rds-aurora/
└── patterns/                # Composiciones de referencia
    └── web-app-ecs/
```

### 4.2 Reglas de Diseño de Módulos (No negociables)

| Regla | Justificación |
|---|---|
| Cero Providers declarados | Los providers se inyectan desde el entorno consumidor para no romper dependencias múltiples. |
| Cero Backends declarados | El manejo del estado es responsabilidad exclusiva del entorno que ejecuta el despliegue. |
| Sin hardcoding | Cero valores fijos de cuentas, regiones, IPs o nombres específicos. Todo debe ser parametrizado. |
| Validación de variables | Toda variable con dominio acotado lleva un bloque `validation` para fallar rápido durante el plan. |
| Etiquetado universal | Todo recurso soporta tags inyectados más etiquetas generadas automáticamente. |

### 4.3 Versionado Semántico (Git Tags)

Los repositorios que consumen la infraestructura siempre deben referenciar un tag
inmutable, nunca `main`.

**Formato:** `<módulo>/vMAJOR.MINOR.PATCH` (Ej: `vpc/v1.2.0`)

```hcl
module "networking" {
  source = "git::https://github.com/benjamin-cloud-pi/PI-Modules.git//modules/vpc?ref=vpc/v1.2.0"
  # ...
}
```

---

## 5. Repositorios Consumidores (Proyectos Live)

Se utiliza un enfoque de separación de estados por capa arquitectónica, no un estado
monolítico. Esto reduce el blast radius (radio de impacto) y los tiempos de ejecución.

### 5.1 Estructura del Entorno

```
tf-live-proyecto-alpha/
├── us-east-1/
│   ├── _regional.tfvars             # Configuración transversal de la región
│   ├── dev/
│   │   ├── _env.tfvars              # Configuración del entorno de desarrollo
│   │   ├── 10-networking/           # Capa 1: VPC, Subnets, Endpoints
│   │   ├── 20-security/             # Capa 2: KMS, IAM, WAF
│   │   ├── 30-data/                 # Capa 3: Bases de datos, Caché
│   │   └── 40-compute/              # Capa 4: ECS, Lambdas
│   └── prod/
```

### 5.2 Decisiones de Arquitectura Live

- **Prefijos Numéricos:** Establecen el orden explícito de dependencias. El pipeline
  ejecuta en orden (la red siempre se crea antes que el cómputo).
- **Estado por Capa:** Un cambio en la aplicación (Capa 40) no requiere evaluar toda la
  infraestructura de red (Capa 10).
- **Comunicación mediante data sources:** Las capas se descubren mediante etiquetas
  (tags) en lugar de depender de `remote_state` rígidos, reduciendo el acoplamiento.
- **Despliegue basado en carpetas (sin Workspaces):** Separa físicamente los entornos,
  evitando que un error humano modifique producción al olvidar cambiar de workspace
  activo.

---

## 6. Controles de Seguridad y Eficiencia por Defecto

Estos controles vienen embebidos de fábrica en los módulos. Suponen una adopción
inmediata de las mejores prácticas del marco AWS Well-Architected.

### 6.1 Seguridad y Compliance

- **Bloqueo Público S3:** Block Public Access activado a nivel de bucket por defecto.
- **Cifrado Transversal:** Integración nativa con KMS para cifrado en reposo en
  volúmenes EBS, bases de datos y buckets.
- **Menor Privilegio IAM:** Generación estricta de políticas sin comodines (`*`) en
  acciones críticas.
- **Tránsito Seguro:** TLS 1.2 mínimo y redirección forzada de HTTP a HTTPS en
  balanceadores.
- **Gestión de Secretos:** Integración nativa con AWS Secrets Manager; prohibición
  estricta de inyectar credenciales como texto plano en las variables de entorno.

### 6.2 Optimización de Costos (FinOps)

- **Etiquetado de Facturación:** Tags obligatorios (`Environment`, `Project`,
  `CostCenter`) validados estáticamente.
- **Retención Finita:** Ningún log en CloudWatch se configura como "Never Expire".
  Valores por defecto razonables (ej. 14 o 30 días).
- **Ciclo de Vida de Datos:** Transición automática a capas de almacenamiento económicas
  (S3 Infrequent Access/Glacier) para artefactos y respaldos antiguos.
- **Eficiencia de Red:** Parametrización para permitir un único NAT Gateway en entornos
  de desarrollo, ahorrando costos fijos significativos.

### 6.3 Observabilidad y Operaciones

- **Métricas y Alarmas Integradas:** Umbrales preconfigurados para consumo de CPU,
  errores HTTP 5xx, y saturación de base de datos.
- **Centralización de Logs:** VPC Flow Logs y application logs exportados y
  centralizados de forma estandarizada.
- **Protección de Estado:** Backend en S3 con versionado obligatorio y bloqueo de
  concurrencia mediante DynamoDB.

---

## 7. Flujo CI/CD de Infraestructura Automática

La validación y aplicación de cambios en la infraestructura se maneja enteramente
mediante automatización, eliminando el despliegue desde terminales locales.

### 7.1 Pipeline del Repositorio de Módulos (Platform)

Se ejecuta en cada Pull Request para garantizar la calidad del código base:

- **Formato:** `terraform fmt -check`
- **Validación estática:** `terraform validate`
- **Linter AWS:** `tflint` enfocado en mejores prácticas del proveedor.
- **Análisis de Seguridad:** `checkov` o `tfsec` bloquean el PR si detectan
  vulnerabilidades (ej. puertos abiertos al mundo).
- **Documentación Automática:** Falla si el README.md no se actualizó tras cambiar una
  variable (vía `terraform-docs`).

### 7.2 Pipeline del Repositorio Consumidor (Live)

Se ejecuta al integrar código en los entornos finales:

- **Pull Request (Plan):** Ejecuta `terraform plan`, evalúa políticas locales y comenta
  el impacto de los recursos en GitHub/GitLab. Opcionalmente integra Infracost para ver
  la variación en el costo mensual.
- **Merge (Apply):** Tras aprobación humana, el pipeline asume un rol de IAM mediante
  federación OIDC (sin credenciales hardcodeadas) y ejecuta el `terraform apply`
  utilizando exactamente el archivo de plan generado en el PR.
- **Auditoría (Nightly):** Ejecución de `terraform plan` periódica para detectar "Drift"
  (cambios manuales en la consola que difieren del código) y emitir alertas.
