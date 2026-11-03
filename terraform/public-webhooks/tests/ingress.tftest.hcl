mock_provider "aws" {}

override_data {
  target = data.aws_instance.opsrabbit
  values = {
    subnet_id            = "subnet-instance"
    availability_zone    = "us-east-1a"
    network_interface_id = "eni-test"
  }
}

override_data {
  target = data.aws_subnet.instance
  values = { vpc_id = "vpc-test" }
}

override_data {
  target = data.aws_subnet.public["subnet-a"]
  values = { vpc_id = "vpc-test", availability_zone = "us-east-1a" }
}

override_data {
  target = data.aws_subnet.public["subnet-b"]
  values = { vpc_id = "vpc-test", availability_zone = "us-east-1b" }
}

variables {
  aws_region         = "us-east-1"
  vpc_id             = "vpc-test"
  public_subnet_ids  = ["subnet-a", "subnet-b"]
  instance_id        = "i-test"
  certificate_arn    = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  opsrabbit_hostname = "hooks.example.com"
  access_log_bucket  = "fixture-alb-logs"
}

run "restricted_ingress" {
  command = plan

  assert {
    condition = (aws_lb_listener.https.port == 443 && aws_lb_listener.https.protocol == "HTTPS" &&
      aws_lb_target_group.webhooks.port == 3000 && aws_lb_target_group.webhooks.protocol == "HTTP" &&
      one(aws_lb_target_group.webhooks.health_check).path == "/api/health" &&
      one(aws_lb_target_group.webhooks.health_check).protocol == "HTTP" &&
    aws_vpc_security_group_ingress_rule.target.from_port == 3000 && aws_vpc_security_group_egress_rule.target.to_port == 3000)
    error_message = "Public HTTPS must reach the installer web HTTP port 3000, with /api/health checks."
  }
  assert {
    condition = one(flatten([
      for condition in aws_lb_listener_rule.webhooks["0"].condition : tolist(condition.host_header)
    ])).values == toset(["hooks.example.com"])
    error_message = "The host condition must use opsrabbit_hostname."
  }
  assert {
    condition     = one(aws_lb_listener.https.default_action).type == "fixed-response" && one(one(aws_lb_listener.https.default_action).fixed_response).status_code == "404"
    error_message = "Unmatched requests must be rejected with a fixed 404."
  }
  assert {
    condition = length(aws_lb_listener_rule.webhooks["0"].condition) == 4 && alltrue([
      for condition in aws_lb_listener_rule.webhooks["0"].condition :
      length(condition.http_header) == 0 ? true : one(condition.http_header).http_header_name == "X-OpsRabbit-Webhook-Token" && one(condition.http_header).values == toset(["?*"])
    ])
    error_message = "Forwarding must require the configured header in addition to host and path."
  }
  assert {
    condition = alltrue([
      for condition in aws_lb_listener_rule.webhooks["0"].condition :
      length(condition.path_pattern) == 0 ? true : one(condition.path_pattern).values == toset(["/webhooks/*"])
    ])
    error_message = "Public forwarding must stay under /webhooks/."
  }
}

run "restricted_source_ranges" {
  command = plan
  variables {
    allowed_webhook_cidrs = ["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"]
  }
  assert {
    condition = length(aws_lb_listener_rule.webhooks) == 2 && toset(flatten([
      for rule in aws_lb_listener_rule.webhooks : [for condition in rule.condition :
        length(condition.source_ip) == 0 ? [] : tolist(one(condition.source_ip).values)
      ]
    ])) == toset(["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"])
    error_message = "Rules must preserve all configured source CIDRs without a public fallback."
  }
  assert {
    condition = alltrue([for rule in aws_lb_listener_rule.webhooks : length(rule.condition) == 4 &&
      sum([for condition in rule.condition : length(condition.source_ip) == 0 ? 1 : length(one(condition.source_ip).values)]) <= 5
    ])
    error_message = "Every CIDR rule must retain all gates and respect the ALB match limit."
  }
}

run "reject_invalid_source_range" {
  command = plan
  variables {
    allowed_webhook_cidrs = ["not-a-cidr"]
  }
  expect_failures = [var.allowed_webhook_cidrs]
}

run "custom_header_name" {
  command = plan
  variables {
    webhook_header_name = "X-Custom-Webhook-Token"
  }
  assert {
    condition = one(flatten([
      for condition in aws_lb_listener_rule.webhooks["0"].condition : tolist(condition.http_header)
    ])).http_header_name == "X-Custom-Webhook-Token"
    error_message = "Clients must be able to override the required header name."
  }
}

run "custom_web_port" {
  command = plan
  variables {
    target_port = 18384
  }
  assert {
    condition = (aws_lb_target_group.webhooks.port == 18384 &&
      aws_lb_target_group_attachment.opsrabbit.port == 18384 &&
      aws_vpc_security_group_ingress_rule.target.from_port == 18384 &&
      aws_vpc_security_group_ingress_rule.target.to_port == 18384 &&
      aws_vpc_security_group_egress_rule.target.from_port == 18384 &&
    aws_vpc_security_group_egress_rule.target.to_port == 18384)
    error_message = "Custom host port must be used consistently for forwarding and security groups."
  }
}

run "reject_before_future_ui_rule" {
  command = plan
  assert {
    condition = (aws_lb_listener_rule.reject_webhooks.priority == 200 && alltrue([
      for rule in aws_lb_listener_rule.webhooks : rule.priority < 200
      ]) && one(one(aws_lb_listener_rule.reject_webhooks.action).fixed_response).status_code == "404" &&
    one(one(aws_lb_listener_rule.reject_webhooks.condition).path_pattern).values == toset(["/webhooks", "/webhooks/*"]))
    error_message = "Reject unqualified webhook requests before any future UI rules at priority 300 or later."
  }
  assert {
    condition     = one(aws_lb.webhooks.access_logs).enabled && one(aws_lb.webhooks.access_logs).bucket == "fixture-alb-logs"
    error_message = "Access logging must use the configured customer bucket."
  }
}

run "reject_trailing_hyphen_name" {
  command = plan
  variables {
    name = "hooks-"
  }
  expect_failures = [var.name]
}

run "reject_reserved_name_prefix" {
  command = plan
  variables {
    name = "internal-hooks"
  }
  expect_failures = [var.name]
}
