/**
 * Instalación del plugin AWS antes del primer uso:
 *   tflint --init
 *
 * Uso:
 *   tflint --recursive --config="$(pwd)/.tflint.hcl"
 *
 * Nota: con --recursive tflint cambia de directorio, así que la ruta al
 * fichero de configuración debe ser absoluta.
 */

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# ---------------------------------------------------------------------------
# Reglas que hacen cumplir las convenciones del repositorio
# ---------------------------------------------------------------------------

# Toda variable y todo output llevan description: es lo que alimenta el README
# generado por terraform-docs.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Toda variable declara type explícitamente. Sin esto Terraform infiere, y los
# errores aparecen en apply en lugar de en plan.
rule "terraform_typed_variables" {
  enabled = true
}

# Declaraciones sin usar: normalmente son restos de un refactor a medias.
rule "terraform_unused_declarations" {
  enabled = true
}

# snake_case en nombres de recursos, variables y outputs.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Todo módulo referenciado debe estar fijado a una versión o tag.
# Es la regla que impide que alguien apunte a una rama.
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "flexible"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Comentarios con # en lugar de //
rule "terraform_comment_syntax" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

# ---------------------------------------------------------------------------
# Reglas AWS
# ---------------------------------------------------------------------------

# Validan que tipos de instancia, clases de RDS y nodos de ElastiCache existan
# de verdad. Evita descubrir una errata a mitad de un apply.
rule "aws_instance_previous_type" {
  enabled = true
}

rule "aws_db_instance_previous_type" {
  enabled = true
}

rule "aws_elasticache_cluster_previous_type" {
  enabled = true
}