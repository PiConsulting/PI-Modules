###############################################################################
# Plan-only tests. No AWS credentials required, no resources created.
#
#   terraform test
#
# These assert the module's *contract*: the things a consumer is allowed to
# rely on and that a refactor must never silently break.
###############################################################################

###############################################################################
# mock_provider sustituye por completo al provider de AWS: no hay credenciales,
# no hay llamadas a la API y no hay coste. Es la opción correcta frente a un
# `provider "aws"` con los skip_* activados, porque aquella todavía instancia el
# provider real y sigue dependiendo de que ningún data source haga una llamada.
#
# Requiere Terraform >= 1.7. El módulo declara ~> 1.9, así que no hay problema.
#
# Los atributos *configurados* (enable_dns_support, cidr_block,
# retention_in_days, map_public_ip_on_launch...) conservan su valor real, que es
# justo lo que afirman los asserts. Solo se inventan los *computed* (IDs, ARNs).
###############################################################################

mock_provider "aws" {

  # Sin esto, data.aws_region.current.region devuelve una cadena aleatoria y los
  # nombres de los VPC endpoints salen distintos en cada ejecución. Fijándolo,
  # el plan es determinista y se puede afirmar sobre él.
  mock_data "aws_region" {
    defaults = {
      region      = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  # aws_iam_role.flow_logs valida que assume_role_policy sea JSON valido antes
  # de llegar a AWS. Sin este mock, aws_iam_policy_document.json sale como
  # cadena aleatoria y esa validacion falla en el plan.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  # El módulo no usa aws_caller_identity, pero los siguientes módulos del
  # catálogo (kms, iam-role, s3) sí lo harán. Se deja documentado aquí para
  # copiar cuando toque:
  #
  # mock_data "aws_caller_identity" {
  #   defaults = {
  #     account_id = "111122223333"
  #     arn        = "arn:aws:iam::111122223333:root"
  #     user_id    = "111122223333"
  #   }
  # }
}

variables {
  name               = "test-dev"
  environment        = "dev"
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

run "defaults_are_secure_and_resilient" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "DNS support and hostnames must be enabled by default."
  }

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "One private subnet per AZ must be created."
  }

  assert {
    condition     = length(aws_subnet.database) == 3
    error_message = "The database tier must be created by default."
  }

  assert {
    condition     = alltrue([for s in values(aws_subnet.private) : s.map_public_ip_on_launch == false])
    error_message = "Private subnets must never auto-assign public IPs."
  }

  assert {
    condition     = alltrue([for s in values(aws_subnet.public) : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not auto-assign public IPs by default; that is the workload's decision."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "Default nat_gateway_mode is one_per_az, so there must be one NAT per AZ."
  }

  assert {
    condition     = length(aws_route_table.private) == 3
    error_message = "one_per_az egress requires one private route table per AZ."
  }

  assert {
    condition     = length(aws_flow_log.this) == 1
    error_message = "Flow logs must be enabled by default."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 30
    error_message = "En dev la retencion por defecto debe ser 30 dias"
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3) == 1
    error_message = "The free S3 gateway endpoint must be enabled by default."
  }

  assert {
    condition     = length(aws_default_security_group.this) == 1
    error_message = "The default security group must be managed and emptied by default."
  }
}

run "cidrs_do_not_overlap_between_tiers" {
  command = plan

  assert {
    condition = length(distinct(concat(
      [for s in values(aws_subnet.public) : s.cidr_block],
      [for s in values(aws_subnet.private) : s.cidr_block],
      [for s in values(aws_subnet.database) : s.cidr_block],
    ))) == 9
    error_message = "Auto-calculated subnet CIDRs must all be distinct across the three tiers."
  }
}

run "single_nat_mode_creates_one_shared_route_table" {
  command = plan

  variables {
    nat_gateway_mode = "single"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single mode must create exactly one NAT gateway."
  }

  assert {
    condition     = length(aws_route_table.private) == 1
    error_message = "single mode must create exactly one shared private route table."
  }
}

run "no_nat_mode_creates_no_egress" {
  command = plan

  variables {
    nat_gateway_mode = "none"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "none mode must not create NAT gateways."
  }

  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "none mode must not create default routes out of the private tier."
  }
}

run "database_tier_is_isolated_by_default" {
  command = plan

  assert {
    condition     = length(aws_route.database_nat) == 0
    error_message = "The database tier must have no default route to the internet unless explicitly requested."
  }
}

run "invalid_environment_is_rejected" {
  command = plan

  variables {
    environment = "qa2"
  }

  expect_failures = [var.environment]
}

run "single_az_is_rejected" {
  command = plan

  variables {
    availability_zones = ["us-east-1a"]
  }

  expect_failures = [var.availability_zones]
}

run "never_expire_log_retention_is_rejected" {
  command = plan

  variables {
    flow_logs_retention_days = 0
  }

  expect_failures = [var.flow_logs_retention_days]
}

run "prod_defaults_to_one_year_retention" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365
    error_message = "En prod la retencion por defecto debe ser 365 dias (CKV_AWS_338)."
  }
}

run "explicit_retention_overrides_environment_default" {
  command = plan

  variables {
    environment              = "prod"
    flow_logs_retention_days = 731
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 731
    error_message = "Un valor explicito debe ganar sobre el default por entorno."
  }
}