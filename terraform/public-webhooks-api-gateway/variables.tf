variable "aws_region" {
  type = string
}

variable "name" {
  type    = string
  default = "opsrabbit-hooks-api"
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$", var.name))
    error_message = "Use 1–20 lowercase letters, digits or hyphens; start with a letter, end with a letter/digit."
  }
}

variable "vpc_id" {
  type = string
}

variable "vpc_link_subnet_ids" {
  description = "Existing subnets in the target VPC for the VPC Link interfaces."
  type        = set(string)
  validation {
    condition     = length(var.vpc_link_subnet_ids) >= 1
    error_message = "Provide at least one subnet supported by VPC Link V2."
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

variable "target_tls_server_name" {
  description = "DNS name on the private listener certificate. Null uses HTTP."
  type        = string
  default     = null
}
