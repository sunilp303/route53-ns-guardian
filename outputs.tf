output "lambda_function_name" {
  value       = aws_lambda_function.this.function_name
  description = "Name of the checker Lambda"
}

output "lambda_function_arn" {
  value       = aws_lambda_function.this.arn
  description = "ARN of the checker Lambda"
}

output "lambda_role_arn" {
  value       = aws_iam_role.this.arn
  description = "IAM role used by the Lambda"
}

output "sns_topic_arn" {
  value       = var.sns_topic_arn != "" ? var.sns_topic_arn : try(aws_sns_topic.this[0].arn, "")
  description = "SNS topic ARN used for alerts"
}

output "schedule" {
  value       = aws_cloudwatch_event_rule.schedule.schedule_expression
  description = "EventBridge schedule expression"
}
