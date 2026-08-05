terraform {
  # Usar rangos de version, no versiones exactas, para mantener la compatibilidad del modulo con diferentes consumidores
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }
}

# Nota: No hay bloques de provider ni backend: la configuracion se modifica desde el
# repositorio raiz y el estado remoto se administra en el respositorio live