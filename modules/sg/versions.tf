terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# Este modulo no declara bloque provider ni backend a proposito: los providers
# los inyecta el root y el backend es responsabilidad del repositorio live.