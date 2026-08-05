# Módulo 1 · Networking / VPC

**Spec de diseño** · Estado: implementado, `v1.0.0`
Código: [`modules/vpc/`](../../modules/vpc/)

---

## 1. Qué problema resuelve

Toda carga de trabajo en AWS vive dentro de una VPC. La VPC es la única pieza de la
arquitectura que **no se puede cambiar en caliente**: modificar el direccionamiento con
producción encima no es un cambio, es una migración con ventana de indisponibilidad.

Los tres problemas concretos que resuelve el módulo:

**a) El coste de equivocarse en el direccionamiento.** Un CIDR mal elegido —demasiado
pequeño, o solapado con la red on-premise del cliente— bloquea el crecimiento y hace
imposible una VPN o un Direct Connect futuros. El módulo no elige el CIDR (eso es una
decisión de arquitectura del cliente), pero fuerza a que sea explícito, validado y
revisable en un pull request.

**b) La inconsistencia entre despliegues.** Sin módulo, cada ingeniero decide cuántas AZ,
cuántos NAT, si activa flow logs, cuánta retención. El resultado es que la postura de
seguridad de un cliente depende de quién estuvo disponible ese sprint. Con el módulo, la
postura es la misma siempre y las desviaciones son explícitas en el código.

**c) El gasto invisible.** Los tres sumideros clásicos de dinero en la capa de red son
NAT gateways que nadie contó, tráfico a S3 saliendo por NAT en lugar de por un endpoint
gratuito, y log groups sin retención. El módulo los ataca por defecto.

---

## 2. En qué arquitecturas se usa

| Arquitectura | Uso | Configuración típica |
|---|---|---|
| **A. ECS Fargate + ALB** | Base completa | 3 AZ, `one_per_az`, 3 capas, endpoints de ECR/logs/secrets |
| **B. Serverless** | Solo si hay Lambda en VPC o Aurora | 2–3 AZ, sin capa pública, `nat_gateway_mode = "none"` + endpoints |
| **C. Estático + API** | Normalmente no lo necesita | — |
| **D. Landing Zone** | Una VPC por cuenta de workload | Direccionamiento coordinado entre cuentas para TGW |
| **E. Datos** | Redshift, EMR, endpoints de Glue | 3 AZ, capa de datos ancha, `none` o `single` |

Además, es dependencia dura de: `security-groups`, `alb`, `ecs-fargate`, `rds-aurora`,
`elasticache` y de cualquier Lambda con configuración de VPC.

---

## 3. Buenas prácticas que debe cumplir

### Por pilar de Well-Architected

| Pilar | Requisito | Cómo se cumple en el código |
|---|---|---|
| **Confiabilidad** | Nunca una sola AZ | `validation` sobre `availability_zones` exige ≥2 |
| | Egreso resiliente | Default `nat_gateway_mode = "one_per_az"`; una tabla de rutas por AZ apuntando a su NAT local |
| | Cambios de AZ no destructivos | `for_each` con clave = AZ en lugar de `count` |
| | Crecimiento sin renumerar | Slots reservados por capa en el cálculo de CIDR |
| **Seguridad** | Menor privilegio | El rol de flow logs se limita al ARN de su log group; sin `*` en `Resource` |
| | Nada público por accidente | `map_public_ip_on_launch = false` incluso en subredes públicas |
| | Aislamiento del dato | Tabla de rutas de la capa de datos sin ruta por defecto (`database_subnets_route_to_nat = false`) |
| | Trazabilidad de red | `enable_flow_logs = true` por defecto |
| | Sin default SG permisivo | `aws_default_security_group` gestionado y vacío |
| | Cifrado de logs | `flow_logs_kms_key_arn` aceptado; CMK recomendada en entornos regulados |
| **Costes** | Egreso proporcional al entorno | El enum `nat_gateway_mode` hace visible el compromiso: `single` ahorra ~64 USD/mes frente a 3 NAT |
| | Sin tráfico innecesario por NAT | `enable_s3_endpoint = true` por defecto (gateway endpoints son gratis) |
| | Retención finita | `validation` rechaza `flow_logs_retention_days = 0` |
| | Granularidad de logs proporcionada | `max_aggregation_interval = 600` por defecto (más barato); 60 solo cuando se necesita |
| **Excelencia operativa** | Nombres deterministas | Compuestos en `locals` a partir de `name`; nunca literales |
| | Etiquetado completo | `local.tags` inyecta `Environment`, `ManagedBy` y `Module` sobre las tags del llamante |
| | Outputs suficientes | Se exponen listas ordenadas *y* mapas por AZ, IDs de tablas de rutas e IPs de NAT |
| | Fallos tempranos | 12 `validation` + 2 `precondition`: los errores aparecen en `plan`, no en `apply` |
| **Eficiencia** | Sin sobredimensionar | Tamaños y número de AZ parametrizados; nada fijo |
| | Latencia a servicios AWS | Interface endpoints opcionales por servicio |

### Prácticas de ingeniería de módulos

- Sin bloques `provider` ni `backend` (rompen `for_each` y aliases, y secuestran una
  decisión del root).
- `required_version` como rango, no pin exacto.
- Cero valores de cliente, cuenta, región o CIDR incrustados.
- Toda variable con `description` y `type` explícito.
- Toda variable de dominio acotado con `validation`.

---

## 4. Variables

La interfaz completa está en
[`variables.tf`](../../modules/vpc/variables.tf). Lo relevante aquí es **por
qué la interfaz es así**.

### Obligatorias — sin default a propósito

| Variable | Tipo | Por qué no tiene default |
|---|---|---|
| `name` | `string` | Un default genera colisiones de nombre entre clientes |
| `environment` | `string` | Debe ser una decisión consciente; además condiciona la postura |
| `vpc_cidr` | `string` | Un CIDR por defecto es la receta perfecta para un solapamiento silencioso |
| `availability_zones` | `list(string)` | Descubrirlas con un data source hace el plan no reproducible: AWS no garantiza el mismo orden entre cuentas |

### Las cuatro decisiones de interfaz que importan

**`nat_gateway_mode` como enum, no `single_nat_gateway = bool`.** Un booleano no puede
expresar "sin NAT en absoluto", que es exactamente lo que quieres en una VPC serverless o
totalmente privada. Además, un enum obliga a que el código del cliente diga
`"one_per_az"` — el compromiso coste/resiliencia queda escrito, no implícito.

**CIDRs auto-calculados *y* explícitos.** El auto-cálculo hace trivial levantar un entorno
de pruebas. Los CIDRs explícitos son obligatorios en producción, porque un plan de
direcciones debe poder revisarse en un PR y no puede depender de una fórmula que cambia si
alguien ajusta `subnet_newbits`. El módulo soporta ambos y la documentación es explícita
sobre cuándo usar cada uno.

**Slots reservados por capa.** El cálculo asigna `subnet_slots_per_tier` (4 por defecto)
ranuras a cada capa aunque solo se usen 2 o 3 AZ. Añadir una cuarta AZ el año que viene
**añade** una subred; no renumera las tres existentes. El coste de esta decisión es
desperdiciar espacio de direcciones; el beneficio es no tener que migrar.

**Tags separadas por capa.** `public_subnet_tags`, `private_subnet_tags` y
`database_subnet_tags` existen porque los controladores de balanceadores (ALB Controller,
EKS) exigen tags de descubrimiento en subredes concretas. Sin esto, el consumidor tendría
que salirse del módulo para etiquetar a mano.

### Validaciones implementadas

| Variable | Regla | Qué previene |
|---|---|---|
| `name` | regex, 3–32 caracteres | Nombres inválidos que fallan a mitad de `apply` |
| `environment` | `dev`\|`stg`\|`prod` | Proliferación de entornos que rompe la automatización |
| `vpc_cidr` | CIDR válido, /16–/24 | VPC imposible de dividir en tres capas |
| `availability_zones` | ≥2, sin duplicados | Topología de una sola AZ |
| `nat_gateway_mode` | enum | Erratas silenciosas |
| `flow_logs_retention_days` | valores válidos de CloudWatch, sin 0 | Retención infinita |
| `instance_tenancy` | enum | `dedicated` accidental (multiplica el coste) |
| `subnet_newbits` / `subnet_slots_per_tier` | rangos | Cálculos de CIDR imposibles |

Y dos `precondition` en recursos, para lo que una `validation` no puede expresar:

- NAT solicitado sin capa pública → error en `plan` con mensaje claro.
- Flow logs a S3 sin ARN de destino → error en `plan`.

---

## 5. Outputs

Ver [`outputs.tf`](../../modules/vpc/outputs.tf). Criterio de diseño:

**Se exponen listas ordenadas *y* mapas por AZ.** Las listas
(`private_subnet_ids`) son lo que consume el 90 % de los módulos. Los mapas
(`private_subnets_by_az`) son necesarios cuando un recurso debe fijarse a una AZ concreta
—una réplica de lectura, un nodo de un clúster—, y sin ellos el consumidor tendría que
hacer aritmética de índices, que es frágil.

**Se exponen decisiones, no solo identificadores.** `nat_gateway_mode` se devuelve tal
cual para que una política OPA o una revisión de arquitectura pueda afirmar
"en producción el modo debe ser `one_per_az`" sin leer el código del cliente.

**`vpc_all_cidr_blocks` en lugar de que cada consumidor recomponga los rangos.** El módulo
de security groups necesita saber qué es "dentro de la VPC". Que lo declare por su cuenta
garantiza que algún día se desincronice cuando se añada un CIDR secundario.

**Todo lo opcional devuelve `null`, no falla.** Cada output de recurso condicional usa
`try(...)`. Un consumidor puede referenciar `database_subnet_group_name` sin saber si la
capa de datos existe.

---

## 6. Recursos que crea

| Recurso | Cantidad | Condición |
|---|---|---|
| `aws_vpc` | 1 | siempre |
| `aws_vpc_ipv4_cidr_block_association` | N | por cada CIDR secundario |
| `aws_default_security_group` | 1 | `manage_default_security_group` |
| `aws_internet_gateway` | 1 | `create_public_subnets` |
| `aws_subnet` (public) | 1 por AZ | `create_public_subnets` |
| `aws_subnet` (private) | 1 por AZ | siempre |
| `aws_subnet` (database) | 1 por AZ | `create_database_subnets` |
| `aws_db_subnet_group` | 1 | `create_database_subnet_group` |
| `aws_eip` + `aws_nat_gateway` | 0, 1 o 1 por AZ | según `nat_gateway_mode` |
| `aws_route_table` (public) | 1 | `create_public_subnets` |
| `aws_route_table` (private) | 1 o 1 por AZ | según `nat_gateway_mode` |
| `aws_route_table` (database) | 1 | `create_database_subnets` |
| `aws_route` | 1 por tabla con salida | según modo |
| `aws_route_table_association` | 1 por subred | siempre |
| `aws_vpc_endpoint` (gateway) | 0–2 | S3, DynamoDB |
| `aws_vpc_endpoint` (interface) | N | `interface_endpoint_services` |
| `aws_security_group` + reglas | 1 + N | si hay interface endpoints |
| `aws_cloudwatch_log_group` | 1 | flow logs a CloudWatch |
| `aws_iam_role` + `aws_iam_role_policy` | 1 + 1 | flow logs a CloudWatch |
| `aws_flow_log` | 1 | `enable_flow_logs` |

**Coste mensual aproximado (us-east-1, sin tráfico):**

| Configuración | Coste base |
|---|---|
| dev: 2 AZ, `single`, sin interface endpoints | ~32 USD |
| prod: 3 AZ, `one_per_az`, 6 interface endpoints | ~96 USD (NAT) + ~126 USD (endpoints) |
| privada: 3 AZ, `none`, 6 interface endpoints | ~126 USD |

A partir de aproximadamente 500 GB/mes de tráfico a servicios de AWS, los interface
endpoints salen más baratos que pagar el procesamiento de datos del NAT. Ese cálculo debe
hacerse por cliente, no asumirse.

---

## 7. Decisiones que el módulo NO debe tomar

La regla es: **el módulo impone lo que no es negociable; el root decide lo que depende del
negocio.**

| Decisión | De quién es | Por qué |
|---|---|---|
| El plan de direccionamiento | Arquitecto + cliente | Depende de la red existente, adquisiciones y planes de peering. Un módulo no puede saberlo |
| Cuántas AZ | Root | Depende del SLA comprometido y del presupuesto |
| Si se necesita capa pública | Root | Una VPC detrás de Transit Gateway no la necesita |
| Qué clave KMS usar | Root (módulo `kms`) | El ciclo de vida de una clave es distinto al de una VPC. Crear la clave aquí la haría morir con la red |
| Dónde viven los buckets de logs | Root (módulo `s3`) | Suelen estar en una cuenta de seguridad distinta |
| Qué security groups de aplicación existen | Módulo `security-groups` | Cambian con cada despliegue; la red no |
| Peering, TGW, VPN, Direct Connect | Módulos de conectividad | Su ciclo de vida es de la organización, no del workload |
| Route 53 y hosted zones privadas | Módulo `route53` | El DNS suele ser transversal a varias VPC |
| Network ACLs personalizadas | Fuera de alcance por ahora | El control por defecto son los SG. Se añadirán cuando un requisito de cumplimiento las exija |
| IPv6 | Fuera de alcance por ahora | Se implementará cuando exista un cliente real que lo pida |

Las dos últimas filas son deliberadas y merecen énfasis: **la tentación de generalizar
antes de tener el segundo caso real es la principal causa de módulos inmantenibles.** Se
generaliza cuando aparece el segundo caso, no antes.

---

## 8. Errores comunes que evita

Ver la tabla completa en el
[README del módulo](../../modules/vpc/README.md#errores-comunes-que-este-módulo-evita).
Los tres que más caros salen:

**Subredes creadas con `count`.** Cuando alguien quita `us-east-1b` de la lista de AZ,
Terraform con `count` no destruye la subred de la AZ b: renumera. La subred de la AZ c pasa
al índice 1, así que Terraform destruye y recrea la subred de c —con todo lo que haya
dentro—. Con `for_each` keyed por AZ, se destruye exactamente la subred de b. Este es el
motivo de la decisión, y es un incidente que se ve en producción con regularidad.

**Un solo NAT en producción.** Ahorra 64 USD/mes y cuesta una caída total del egreso
cuando falla la AZ que lo aloja. El módulo lo permite, pero hay que escribirlo
explícitamente, y el output `nat_gateway_mode` permite que una política automatizada lo
detecte en producción.

**Log group sin retención.** CloudWatch Logs por defecto es "never expire". Un cliente con
flow logs `ALL` en una VPC con tráfico serio genera decenas de GB al día. A 0,50 USD/GB de
almacenamiento, en un año son miles de dólares por datos que nadie va a consultar. La
`validation` que rechaza el valor 0 es cinco líneas de código y es probablemente el mejor
retorno por línea de todo el módulo.

---

## 9. Estructura de archivos

```
modules/vpc/
├── README.md                    # Referencia de uso
├── versions.tf                  # required_version + required_providers
├── variables.tf                 # 30 variables, todas con description y validation donde aplica
├── locals.tf                    # Cálculo de CIDRs, mapas de subredes, mapeo AZ→tabla de rutas
├── main.tf                      # Recursos, agrupados por bloque funcional
├── outputs.tf                   # 28 outputs
├── examples/
│   ├── minimal/main.tf          # Smoke test: entrada mínima
│   └── complete/main.tf         # Integración: todo activado
└── tests/
    └── defaults.tftest.hcl      # Tests de contrato (plan-only, sin credenciales)
```

**Por qué `locals.tf` separado.** Todo el cálculo no trivial —CIDRs, mapas de subredes,
qué NAT usa cada tabla de rutas— está en un solo archivo. `main.tf` queda como una lista
declarativa de recursos, legible de arriba abajo. Cuando alguien tiene que entender *cómo
se decide* algo, sabe dónde mirar.

**Por qué dos ejemplos y no uno.** `minimal` documenta qué significan los defaults;
`complete` documenta el techo de capacidades. En CI, el primero es el smoke test y el
segundo el test de integración.

---

## 10. Uso desde el repositorio live

Repo live con **Terraform puro**, carpeta por cliente / región / entorno / capa.
Implementación completa en
[`examples-live/acme/us-east-1/prod/10-networking/`](../../examples-live/acme/us-east-1/prod/10-networking/).

```hcl
# examples-live/acme/us-east-1/prod/10-networking/main.tf
module "vpc" {
  source = "git::https://github.com/benjamin-cloud-pi/PI-Modules.git//modules/vpc?ref=vpc/v1.0.0"

  name        = var.name_prefix     # acme-prod
  environment = var.environment     # prod

  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs

  nat_gateway_mode              = var.nat_gateway_mode
  database_subnets_route_to_nat = false

  interface_endpoint_services = var.interface_endpoint_services
  flow_logs_retention_days    = var.flow_logs_retention_days
  flow_logs_kms_key_arn       = var.flow_logs_kms_key_arn

  tags = {
    Project    = var.project
    Owner      = var.owner
    CostCenter = var.cost_center
  }
}
```

```bash
terraform init -backend-config=backend.hcl

terraform plan \
  -var-file=../../_regional.tfvars \
  -var-file=../_env.tfvars \
  -var-file=terraform.tfvars \
  -out=tfplan

terraform apply tfplan   # sobre el plan aprobado, sin replanificar
```

**Los tres niveles de tfvars** (región → entorno → capa) evitan repetir la lista de AZ o
el `CostCenter` en cada capa. Cambiar el email del equipo responsable es un cambio en un
solo archivo.

> **Nota sobre Terragrunt.** El módulo es agnóstico: no declara `provider` ni `backend`,
> así que funciona igual desde un `terragrunt.hcl` con `generate` e `include`. Si en
> algún momento el número de capas hace pesado el mantenimiento de los roots duplicados,
> la migración a Terragrunt no exige tocar ni una línea del módulo.

---

## 11. Versionado

**Tag:** `vpc/vMAJOR.MINOR.PATCH`

```bash
git tag -a vpc/v1.0.0 -m "vpc: release inicial"
git push origin vpc/v1.0.0
```

| Cambio | Bump | Motivo |
|---|---|---|
| Eliminar o renombrar variable/output | MAJOR | Rompe a los consumidores |
| Cambiar el cálculo de CIDR por defecto | MAJOR | Recrea subredes → recrea todo lo que hay dentro |
| Cambiar el default de `nat_gateway_mode` | MAJOR | Cambia el coste y la topología sin que el consumidor lo pida |
| Añadir soporte IPv6 tras un flag desactivado | MINOR | Nadie se ve afectado hasta que lo activa |
| Nuevo output | MINOR | Aditivo |
| Aceptar un nuevo servicio de interface endpoint | MINOR | Aditivo |
| Corregir un mensaje de error o una `validation` demasiado estricta | PATCH | Sin cambio de interfaz |

**Cambios que fuerzan recreación → siempre MAJOR + guía de migración** en
`docs/migrations/vpc-v1-to-v2.md`, con los comandos `terraform state mv` necesarios y una
estimación honesta del impacto.

**Política de soporte:** se mantienen las dos últimas MAJOR. Cuando se publica v3.0.0, la
v1 pasa a fin de vida con 6 meses de aviso.

---

## 12. Checklist de validación antes de producción

Ver el
[checklist completo en el README](../../modules/vpc/README.md#checklist-antes-de-producción).

**Los cinco puntos que hay que verificar sin excepción:**

1. El CIDR **no solapa** con on-premise, con otras VPC del cliente ni con rangos
   reservados para futuras adquisiciones. Se confirma por escrito con el equipo de redes
   del cliente, no se asume.
2. Los CIDRs de subred están **explícitos** en el `tfvars`, no auto-calculados.
3. `nat_gateway_mode = "one_per_az"` y `private_route_table_ids` tiene tantas entradas
   como AZ.
4. Flow logs activos, con retención acorde a la política de cumplimiento y cifrados con
   CMK si el dato es regulado.
5. `terraform destroy` probado en un entorno desechable: sin recursos huérfanos, sin EIP
   sueltas facturando.

---

## Estado y siguiente paso

| | |
|---|---|
| Spec | ✅ |
| Implementación | ✅ |
| Ejemplos (minimal + complete) | ✅ |
| Tests de contrato | ✅ |
| Ejemplo de repo live | ✅ |
| Despliegue real en laboratorio | ⬜ **pendiente — requiere cuenta AWS** |
| CI (fmt, validate, tflint, checkov, terraform-docs) | ⬜ pendiente |
| Tag `vpc/v1.0.0` | ⬜ pendiente tras el despliegue real |

**Siguiente módulo:** `security/security-groups`. Consumirá `vpc_id` y
`vpc_all_cidr_blocks` de este módulo, y su decisión de diseño central será cómo modelar
las reglas entre capas sin caer en un mapa de configuración imposible de leer.
