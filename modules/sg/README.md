# sg

Security group con reglas validadas, pensado para componerse en cadena entre capas.

> **Spec de diseño:** [`docs/modules/02-sg.md`](../../docs/modules/02-sg.md)

---

## Qué resuelve

Crea **un** security group con sus reglas de entrada y salida, y hace imposibles los
cuatro errores que se repiten siempre:

1. `0.0.0.0/0` sobre un puerto administrativo o de base de datos
2. Reglas sin descripción, que vuelven el grupo inauditable
3. `DependencyViolation` al modificar un grupo que ya está en uso
4. Mezclar reglas inline con recursos de regla separados

**Es un módulo de disciplina, no de ahorro de tipeo.** En líneas de código no gana mucho
frente a escribir `aws_security_group` a mano; lo que gana son las validaciones que no se
pueden desactivar y dos detalles de ciclo de vida que casi todo el mundo descubre en
producción.

## Cuándo usarlo

| Úsalo cuando | No lo uses cuando |
|---|---|
| Necesitas controlar el tráfico hacia cualquier recurso en VPC | El SG lo gestiona otro módulo (los endpoints de interfaz los crea `vpc`) |
| Quieres encadenar capas: ALB → app → datos | Necesitas reglas entre cuentas o vía peering — fuera de alcance en v1 |
| Quieres que una revisión detecte reglas peligrosas antes del apply | Solo hay un puerto trivial y no vas a versionar nada |

## Arquitecturas que lo usan

Todas. Junto con `vpc`, es el módulo con más consumidores del catálogo.

| Arquitectura | Grupos típicos |
|---|---|
| A. ECS Fargate + ALB | `alb`, `app`, `database` |
| B. Serverless | `lambda`, `database`, solo si hay recursos en VPC |
| D. Landing Zone | los de los servicios compartidos |
| E. Datos | `redshift`, `emr` |

---

## Diagrama

```
        Internet
           │ 443, 80
   ┌───────▼────────┐
   │  sg (rol alb)  │  ingress: 0.0.0.0/0
   └───────┬────────┘  egress:  abierto
           │ 8080  ── referenced_security_group_id
   ┌───────▼────────┐
   │  sg (rol app)  │  ingress: solo desde el SG del ALB
   └───────┬────────┘  egress:  abierto
           │ 5432  ── referenced_security_group_id
   ┌───────▼────────┐
   │ sg (rol datos) │  ingress: solo desde el SG de app
   └────────────────┘  egress:  restringido
```

La cadena se expresa **solo con reglas de entrada**. Esa es la razón de fondo por la que
la salida va abierta por defecto: con reglas de salida en ambos sentidos aparecería una
dependencia circular entre invocaciones del módulo.

---

## Uso mínimo

```hcl
module "sg_alb" {
  source = "git::https://github.com/benjamin-cloud-pi/PI-Modules.git//modules/sg?ref=sg/v1.0.0"

  name        = "acme-prod-alb"
  environment = "prod"
  vpc_id      = module.vpc.vpc_id
  description = "Balanceador publico de la plataforma"

  ingress_rules = {
    "https-internet" = {
      description = "HTTPS desde internet"
      from_port   = 443
      to_port     = 443
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = local.common_tags
}
```

## Uso completo

Ver [`examples/complete`](examples/complete/main.tf): la cadena de tres capas sobre una
VPC creada por el módulo `vpc`, en un solo apply.

---

## Decisiones de diseño

| Decisión | Por qué |
|---|---|
| **`ingress_rules` es un mapa, no una lista** | Con `for_each` sobre una lista, la clave sale del contenido. Si una regla referencia un SG creado en el mismo apply, ese ID es desconocido en plan y Terraform aborta con *"the given keys must be known"*. Con un mapa la clave la pone el consumidor y siempre se conoce. Es lo que permite levantar la cadena entera de una vez |
| **Un SG por invocación, no la cadena completa** | Genérico y componible. El cableado entre capas es decisión del root, o de `patterns/web-app-ecs` cuando exista |
| **`name_prefix`, no `name`** | `create_before_destroy` es obligatorio para evitar `DependencyViolation`; y con él conviven dos SGs unos segundos, así que los nombres deben ser únicos |
| **`create_before_destroy` también en las reglas** | Cuando el SG padre se reemplaza, las reglas se reemplazan con él. Sin esto el orden de operaciones puede dejar reglas apuntando a un SG inexistente |
| **Egress abierto por defecto** | Es el comportamiento de AWS, evita ciclos y evita el grueso de los tickets de conectividad. Restringir es una decisión consciente del consumidor |
| **`aws_vpc_security_group_ingress_rule`, no el recurso legacy** | Da un ID por regla y admite tags; `aws_security_group_rule` no hace ninguna de las dos cosas |
| **Nunca bloques `ingress`/`egress` inline** | Mezclarlos con recursos separados hace que Terraform borre reglas en cada apply, en bucle |
| **`description` obligatoria y con longitud mínima** | AWS la acepta vacía. Un grupo con 40 reglas sin describir no se puede auditar, así que no se limpia nunca |

## Lo que este módulo NO hace

- **No decide qué grupos existen ni cómo se encadenan.** Eso es del root.
- **No conoce los puertos de tu aplicación.** Son una propiedad del workload.
- **No se adjunta a ningún recurso.** Lo hacen los módulos de cómputo y datos.
- **No gestiona el SG por defecto de la VPC.** Ya lo vacía el módulo `vpc`.
- **No soporta prefix lists, IPv6 ni self-reference.** Fuera de alcance en v1; se añadirán cuando exista un caso real.
- **No admite `protocol = "-1"` en reglas de usuario.** Usa `allow_all_egress` para la salida abierta.

## Errores comunes que evita

| Error | Consecuencia | Cómo lo evita |
|---|---|---|
| `0.0.0.0/0` en 22 o 5432 | Brecha | `validation`, sin variable para desactivarla |
| Rango `0-65535` abierto "temporalmente" | Ídem | La validación comprueba rangos, no puertos exactos |
| Reglas sin descripción | Grupo inauditable que crece para siempre | `validation` de longitud mínima |
| `DependencyViolation` al modificar | Apply a medias en producción | `create_before_destroy` |
| `InvalidGroupName.Duplicate` | El arreglo anterior mal hecho | `name_prefix` |
| Reglas que se borran solas en cada apply | Bucle infinito de cambios | El módulo nunca usa bloques inline |
| No poder levantar la cadena de una vez | `depends_on` y dos pasadas | Mapa con clave del consumidor |

## Limitaciones conocidas

**Reordenar `cidr_blocks` recrea esas reglas.** El índice de la clave aplanada sale de la
posición en la lista. Es barato —una regla se recrea en segundos, sin pérdida de datos— y
la alternativa (derivar la clave del valor) rompe el caso de los IDs desconocidos, que es
justo lo que este diseño resuelve.

**`egress_rules` se ignora si `allow_all_egress = true`.** En silencio, a propósito:
permite dejar las reglas escritas mientras se prueba con salida abierta. El output
`allow_all_egress` te dice qué política se aplicó de verdad.

**`name` no coincide con el nombre real en AWS.** Al usar `name_prefix`, AWS añade un
sufijo aleatorio. El output `name` devuelve el nombre real.

---

## Cómo probarlo

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test          # 19 runs, con mock_provider: sin credenciales ni coste
tflint --recursive
```

## Checklist antes de producción

**Seguridad**

- [ ] Ningún grupo con `0.0.0.0/0` fuera de 80 y 443 en el rol de balanceador
- [ ] La capa de aplicación acepta tráfico solo desde el SG del ALB, nunca por CIDR
- [ ] La capa de datos acepta tráfico solo desde el SG de aplicación
- [ ] Toda regla tiene una descripción que explica el *por qué*
- [ ] Ninguna regla que nadie sepa justificar

**Operación**

- [ ] Nombres siguiendo `<cliente>-<entorno>-<rol>`
- [ ] Probado **modificar** un grupo ya adjunto a un recurso, no solo crearlo — es el único escenario donde aparece `DependencyViolation`
- [ ] Tags completos
- [ ] `terraform destroy` limpio

**Diseño**

- [ ] Si `allow_all_egress = false`, están cubiertos DNS, NTP, los VPC endpoints y las actualizaciones
- [ ] Las claves del mapa describen la regla y son estables

---

## Requisitos

| Nombre | Versión |
|---|---|
| terraform | ~> 1.9 |
| aws | >= 6.0, < 7.0 |

## Inputs

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
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.allow_all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_description"></a> [description](#input\_description) | Descripcion del sg. Sin default a proposito: AWS pone 'Managed by Terraform', que no dice absolutamente nada sobre para que sirve el grupo. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Entorno de despliegue | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Nombre base del sg. Convencion: <cliente>-<entorno>-<rol>, por ejemplo acme-prod-alb, se usa como name\_prefix, asi AWS le añade un subfijo aleatorio | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID de la VPC donde vive el SG | `string` | n/a | yes |
| <a name="input_allow_all_egress"></a> [allow\_all\_egress](#input\_allow\_all\_egress) | Permitir toda la salida a 0.0.0.0/0. Es lo que AWS pone por defecto. Poner en false solo cuando el cliente exija egress restringido, recordar abrir DNS, NTP, los VPC endpoints y las actualizaciones de paquetes. | `bool` | `true` | no |
| <a name="input_egress_rules"></a> [egress\_rules](#input\_egress\_rules) | Reglas de salida explicitas. Solo se aplican cuando allow\_all\_egress es false. Misma estructura que ingress\_rules, pero source\_security\_group\_ids se interpreta como destino. | <pre>map(object({<br/>    description               = string<br/>    from_port                 = number<br/>    to_port                   = number<br/>    protocol                  = optional(string, "tcp")<br/>    cidr_blocks               = optional(list(string), [])<br/>    source_security_group_ids = optional(list(string), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_ingress_rules"></a> [ingress\_rules](#input\_ingress\_rules) | Reglas de entrada, indexadas por un nombre descriptivo elegido por el consumidor. Cada entrada genera un recurso de regla por cada CIDR y por cada sg | <pre>map(object({<br/>    description               = string<br/>    from_port                 = number<br/>    to_port                   = number<br/>    protocol                  = optional(string, "tcp")<br/>    cidr_blocks               = optional(list(string), [])<br/>    source_security_group_ids = optional(list(string), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags aplicados al sg y cada regla. Se esperan las asignaciones: Project, Owner, CostCenter | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_allow_all_egress"></a> [allow\_all\_egress](#output\_allow\_all\_egress) | Politica de salida aplicada realmente. Se devuelve para que una revision de arquitectura o una politica automatizada pueda afirmar sobre ella sin leer el codigo del consumidor. |
| <a name="output_arn"></a> [arn](#output\_arn) | ARN del security group. Para politicas IAM que restringen por grupo. |
| <a name="output_egress_rule_ids"></a> [egress\_rule\_ids](#output\_egress\_rule\_ids) | Mapa de clave a ID de regla de salida. Cuando allow\_all\_egress es true contiene una unica entrada, allow-all. |
| <a name="output_id"></a> [id](#output\_id) | ID del security group. Es el output que sostiene el encadenado entre capas: se pasa a source\_security\_group\_ids de otra invocacion de este mismo modulo, o a los modulos de computo y datos. |
| <a name="output_ingress_rule_count"></a> [ingress\_rule\_count](#output\_ingress\_rule\_count) | Numero de reglas de entrada creadas. Util para detectar grupos que han ido creciendo sin control. |
| <a name="output_ingress_rule_ids"></a> [ingress\_rule\_ids](#output\_ingress\_rule\_ids) | Mapa de clave aplanada a ID de regla de entrada. Para auditoria y para politicas que referencian una regla concreta. |
| <a name="output_name"></a> [name](#output\_name) | Nombre real generado por AWS a partir del name\_prefix. No coincide con var.name: lleva un sufijo aleatorio, consecuencia necesaria de create\_before\_destroy. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC donde vive el security group. Se devuelve para que los modulos consumidores puedan afirmar que estan en la misma red sin volver a resolverlo. |
<!-- END_TF_DOCS -->

## Outputs principales

| Output | Consumido por |
|---|---|
| `id` | Todo: `alb`, `ecs-fargate`, `rds-aurora`, y otras invocaciones de este módulo para encadenar |
| `arn` | Políticas IAM que restringen por grupo |
| `name` | Nombre real generado a partir del `name_prefix` |
| `ingress_rule_ids` | Auditoría; políticas que referencian una regla concreta |
| `allow_all_egress` | Políticas automatizadas que verifican la postura de salida |
| `ingress_rule_count` | Detectar grupos que crecen sin control |

---

## Versionado

Tags: `sg/vMAJOR.MINOR.PATCH`

| Cambio | Bump |
|---|---|
| Cambiar la forma del objeto de regla | MAJOR |
| Pasar `allow_all_egress` a `false` por defecto | MAJOR |
| Cambiar el esquema de claves del aplanado | MAJOR |
| **Añadir puertos a la lista de prohibidos** | **MAJOR** — un consumidor que hoy pasa el plan mañana no lo pasa |
| Soporte de prefix lists o IPv6 tras campo opcional | MINOR |
| Nuevo output | MINOR |
| Mensaje de error más claro | PATCH |

## Changelog

### v1.0.0

- Release inicial: un SG por invocación, reglas por CIDR y por security group de origen,
  cinco validaciones sobre las reglas de entrada, egress abierto configurable, y
  `name_prefix` + `create_before_destroy` resueltos.
