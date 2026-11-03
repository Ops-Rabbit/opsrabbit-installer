data "aws_instance" "opsrabbit" {
  instance_id = var.instance_id
}

data "aws_subnet" "instance" {
  id = data.aws_instance.opsrabbit.subnet_id
}

data "aws_subnet" "public" {
  for_each = var.public_subnet_ids
  id       = each.value
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public HTTPS webhook ingress"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "target" {
  name_prefix = "${var.name}-target-"
  description = "Allow webhook ALB to OpsRabbit web HTTP listener"
  vpc_id      = var.vpc_id
}

resource "aws_network_interface_sg_attachment" "target" {
  security_group_id    = aws_security_group.target.id
  network_interface_id = data.aws_instance.opsrabbit.network_interface_id
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "target" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.target.id
  ip_protocol                  = "tcp"
  from_port                    = var.target_port
  to_port                      = var.target_port
}

resource "aws_vpc_security_group_ingress_rule" "target" {
  security_group_id            = aws_security_group.target.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.target_port
  to_port                      = var.target_port
}

resource "aws_lb" "webhooks" {
  name                       = var.name
  internal                   = false
  load_balancer_type         = "application"
  ip_address_type            = "ipv4"
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  preserve_host_header       = true
  idle_timeout               = 60

  dynamic "access_logs" {
    for_each = var.access_log_bucket == null ? [] : [var.access_log_bucket]
    content {
      enabled = true
      bucket  = access_logs.value
      prefix  = var.name
    }
  }

  lifecycle {
    precondition {
      condition     = data.aws_subnet.instance.vpc_id == var.vpc_id && alltrue([for subnet in data.aws_subnet.public : subnet.vpc_id == var.vpc_id])
      error_message = "Instance and all ALB subnets must belong to vpc_id."
    }
    precondition {
      condition     = length(toset([for subnet in data.aws_subnet.public : subnet.availability_zone])) >= 2
      error_message = "ALB subnets must span at least two availability zones."
    }
    precondition {
      condition     = contains([for subnet in data.aws_subnet.public : subnet.availability_zone], data.aws_instance.opsrabbit.availability_zone)
      error_message = "Enable the instance availability zone in the ALB subnet selection."
    }
  }
}

resource "aws_lb_target_group" "webhooks" {
  name        = "${var.name}-web"
  vpc_id      = var.vpc_id
  target_type = "instance"
  protocol    = "HTTP"
  port        = var.target_port

  health_check {
    protocol            = "HTTP"
    path                = "/api/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "opsrabbit" {
  target_group_arn = aws_lb_target_group.webhooks.arn
  target_id        = var.instance_id
  port             = var.target_port
  depends_on       = [aws_network_interface_sg_attachment.target, aws_vpc_security_group_ingress_rule.target]
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.webhooks.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "Not found"
    }
  }
}

resource "aws_lb_listener_rule" "webhooks" {
  # Each rule has three existing match evaluations; AWS allows five total.
  for_each = { for index, cidrs in chunklist(sort(tolist(var.allowed_webhook_cidrs)), 2) : tostring(index) => cidrs }

  listener_arn = aws_lb_listener.https.arn
  priority     = 100 + tonumber(each.key)

  condition {
    host_header {
      values = [var.opsrabbit_hostname]
    }
  }
  condition {
    path_pattern {
      values = ["/webhooks/*"]
    }
  }
  condition {
    source_ip {
      values = each.value
    }
  }
  condition {
    http_header {
      http_header_name = var.webhook_header_name
      # Require a non-empty value; authenticate the instance token in OpsRabbit.
      values = ["?*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webhooks.arn
  }
}

# Keep this rejection ahead of any future UI rule (use priority 300 or later).
resource "aws_lb_listener_rule" "reject_webhooks" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 200
  condition {
    path_pattern {
      values = ["/webhooks", "/webhooks/*"]
    }
  }
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "Not found"
    }
  }
}

resource "aws_route53_record" "webhooks" {
  count   = var.route53_zone_id == null ? 0 : 1
  zone_id = var.route53_zone_id
  name    = var.opsrabbit_hostname
  type    = "A"
  alias {
    name                   = aws_lb.webhooks.dns_name
    zone_id                = aws_lb.webhooks.zone_id
    evaluate_target_health = false
  }
}
