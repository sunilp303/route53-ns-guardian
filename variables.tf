variable "parent_zone_id" {
  description = "Route53 Hosted Zone ID of the parent domain (e.g. terraform-r53.example.cloud)"
  type        = string
}

variable "parent_domain" {
  description = "Fully-qualified parent domain name (trailing dot optional — Lambda normalises it)"
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for alerts. Leave empty to disable."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sns_topic_arn" {
  description = "Existing SNS topic ARN to publish alerts to. Leave empty and a new topic is created."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address to subscribe to the SNS topic (only used when sns_topic_arn is empty)"
  type        = string
  default     = ""
}

variable "schedule_expression" {
  description = "EventBridge cron/rate expression. Default: every 6 hours."
  type        = string
  default     = "rate(24 hours)"
}

variable "dry_run" {
  description = "If true, Lambda reports findings but does NOT delete any records."
  type        = bool
  default     = true # safe default — flip to false once you're happy with alerts
}

variable "auto_remediate" {
  description = "If true AND dry_run is false, Lambda auto-deletes dangling NS records."
  type        = bool
  default     = false # explicit opt-in required
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    purpose     = "security-automation"
    team        = "sunil@example.com"
    environment = "development"
    terraform   = "true"
    application = "route53-ns-guardian"
  }
}
