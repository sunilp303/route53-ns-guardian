locals {
  function_name = "route53-dangling-ns-checker"
  lambda_zip    = "${path.module}/lambda_package.zip"
}

# ── archive ────────────────────────────────────────────────────────────────────

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/dangling_ns_checker.py"
  output_path = local.lambda_zip
}


# ── IAM ────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "permissions" {
  # Route53 read
  statement {
    sid    = "Route53Read"
    effect = "Allow"
    actions = [
      "route53:ListResourceRecordSets",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
    ]
    resources = ["*"]
  }

  # Route53 write — only needed when AUTO_REMEDIATE=true
  statement {
    sid    = "Route53Delete"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${var.parent_zone_id}"
    ]
  }

  # SNS publish
  dynamic "statement" {
    for_each = var.sns_topic_arn != "" ? [1] : []
    content {
      sid       = "SNSPublish"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [var.sns_topic_arn]
    }
  }

  # CloudWatch Logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/${local.function_name}*"]
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "${local.function_name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}


# ── Lambda ─────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  description      = "Detects dangling Route53 NS delegations with no backing hosted zone"
  role             = aws_iam_role.this.arn
  filename         = local.lambda_zip
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "dangling_ns_checker.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      PARENT_ZONE_ID    = var.parent_zone_id
      PARENT_DOMAIN     = var.parent_domain
      SLACK_WEBHOOK_URL = var.slack_webhook_url
      SNS_TOPIC_ARN     = var.sns_topic_arn
      DRY_RUN           = tostring(var.dry_run)
      AUTO_REMEDIATE    = tostring(var.auto_remediate)
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]
  tags       = var.tags
}


# ── EventBridge (scheduled trigger) ───────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${local.function_name}-schedule"
  description         = "Triggers dangling NS checker every 6 hours"
  schedule_expression = var.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}


# ── SNS topic (optional — created only if no existing ARN is supplied) ─────────

resource "aws_sns_topic" "this" {
  count = var.sns_topic_arn == "" ? 1 : 0
  name  = "${local.function_name}-alerts"
  tags  = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.sns_topic_arn == "" && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.this[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}


# ── CloudWatch Alarm — if Lambda errors spike ──────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.function_name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Dangling NS checker Lambda threw an error"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : (
    length(aws_sns_topic.this) > 0 ? [aws_sns_topic.this[0].arn] : []
  )

  tags = var.tags
}
