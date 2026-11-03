variable "aws_region" {
  type = string
}

variable "name" {
  type    = string
  default = "opsrabbit-hooks"
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$", var.name)) && !startswith(var.name, "internal-")
    error_message = "Use 1–20 lowercase letters, digits or hyphens; start with a letter, end with a letter/digit, and avoid the reserved internal- prefix."
  }
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = set(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Provide public subnets in at least two availability zones."
  }
}

variable "instance_id" {
  type = string
}

variable "certificate_arn" {
  description = "Issued ACM certificate in aws_region covering opsrabbit_hostname."
  type        = string
}

variable "opsrabbit_hostname" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.opsrabbit_hostname)) && !strcontains(var.opsrabbit_hostname, "..")
    error_message = "Use a lowercase DNS hostname without a scheme, path or wildcard."
  }
}

variable "route53_zone_id" {
  description = "Existing public hosted zone ID; null leaves DNS to the operator."
  type        = string
  default     = null
}

variable "target_port" {
  description = "Installer web HTTP port reachable on the EC2 private IP (WEB_HTTP_PORT defaults to 3000)."
  type        = number
  default     = 3000
  validation {
    condition     = var.target_port >= 1 && var.target_port <= 65535 && floor(var.target_port) == var.target_port
    error_message = "Target port must be an integer from 1 to 65535."
  }
}

variable "enable_deletion_protection" {
  type    = bool
  default = true
}

variable "webhook_header_name" {
  default     = "X-OpsRabbit-Webhook-Token"
  description = "Header required at the ALB; OpsRabbit validates its value for each webhook instance."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.webhook_header_name)) && !contains(["host", "authorization", "content-type", "user-agent", "x-forwarded-for", "x-forwarded-proto"], lower(var.webhook_header_name))
    error_message = "Use a custom header containing only letters, digits and hyphens, not a standard routing/authentication header."
  }
}

variable "allowed_webhook_cidrs" {
  description = "IPv4 source CIDRs allowed to reach /webhooks/*, in addition to the required header. Uses the client connection IP, not X-Forwarded-For."
  type        = set(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.allowed_webhook_cidrs) >= 1 && length(var.allowed_webhook_cidrs) <= 100 && alltrue([for cidr in var.allowed_webhook_cidrs : can(cidrnetmask(cidr))])
    error_message = "Provide 1–100 valid IPv4 CIDRs. Default allows all IPv4 addresses."
  }
}

variable "access_log_bucket" {
  default     = null
  description = "Optional existing same-region S3 bucket for ALB access logs; null disables logging."
  type        = string
  validation {
    condition     = var.access_log_bucket == null ? true : length(var.access_log_bucket) >= 3 && length(var.access_log_bucket) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.access_log_bucket))
    error_message = "Provide the existing access-log bucket name, not an ARN or s3:// URL."
  }
}
