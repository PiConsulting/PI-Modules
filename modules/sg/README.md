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