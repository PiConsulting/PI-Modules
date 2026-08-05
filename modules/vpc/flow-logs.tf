###############################################################################
# Flow logs
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = local.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn

  tags = merge(
    local.tags,
    { Name = "${var.name}-flow-logs" }
  )
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogsStream",
      "logs:PutLogEvents",
      "logs:DescribeLogsStreams"
    ]

    # Restringe el acceso únicamente a este grupo de registros, evitando el uso de comodines (*)
    resources = [aws_cloudwatch_log_group.flow_logs[0].arn, "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  description        = "Permite a los VPC Flow Logs enviar registros al Log Group de CloudWatch Logs para ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.flow_logs_to_cloudwatch ? 1 : 0

  name   = "${var.name}-vpc-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_logs_traffic_type
  max_aggregation_interval = var.flow_logs_max_aggregation_interval

  log_destination_type = var.flow_logs_destination_type
  log_destination      = local.flow_logs_to_cloudwatch ? aws_cloudwatch_log_group.flow_logs[0].arn : var.flow_logs_s3_destination_arn
  iam_role_arn         = local.flow_logs_to_cloudwatch ? aws_iam_role.flow_logs[0].arn : null

  tags = merge(
    local.tags,
    { Name = "${var.name}-flow-logs" }
  )

  lifecycle {
    precondition {
      condition     = !local.flow_logs_to_s3 || var.flow_logs_s3_destination_arn != null
      error_message = "Debe especificarse flow_logs_s3_destination_arn cuando flow_logs_destination_type es 's3'"
    }
  }
}
