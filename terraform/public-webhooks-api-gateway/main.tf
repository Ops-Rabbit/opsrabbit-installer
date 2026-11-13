data "aws_instance" "opsrabbit" {
  instance_id = var.instance_id
}

data "aws_subnet" "instance" {
  id = data.aws_instance.opsrabbit.subnet_id
}

data "aws_subnet" "link" {
  for_each = var.vpc_link_subnet_ids
  id       = each.value
}

resource "aws_security_group" "link" {
  name_prefix = "${var.name}-link-"
  description = "API Gateway VPC Link to the OpsRabbit web listener"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "target" {
  name_prefix = "${var.name}-target-"
  description = "Allow VPC Link to the OpsRabbit web listener"
  vpc_id      = var.vpc_id
}

resource "aws_network_interface_sg_attachment" "target" {
  security_group_id    = aws_security_group.target.id
  network_interface_id = data.aws_instance.opsrabbit.network_interface_id
}

resource "aws_vpc_security_group_egress_rule" "target" {
  security_group_id            = aws_security_group.link.id
  referenced_security_group_id = aws_security_group.target.id
  ip_protocol                  = "tcp"
  from_port                    = var.target_port
  to_port                      = var.target_port
}

resource "aws_vpc_security_group_ingress_rule" "target" {
  security_group_id            = aws_security_group.target.id
  referenced_security_group_id = aws_security_group.link.id
  ip_protocol                  = "tcp"
  from_port                    = var.target_port
  to_port                      = var.target_port
}

resource "aws_apigatewayv2_vpc_link" "webhooks" {
  name               = var.name
  subnet_ids         = var.vpc_link_subnet_ids
  security_group_ids = [aws_security_group.link.id]

  lifecycle {
    precondition {
      condition     = data.aws_subnet.instance.vpc_id == var.vpc_id && alltrue([for subnet in data.aws_subnet.link : subnet.vpc_id == var.vpc_id])
      error_message = "The instance and all VPC Link subnets must belong to vpc_id."
    }
  }
}

resource "aws_service_discovery_http_namespace" "webhooks" {
  name = var.name
}

resource "aws_service_discovery_service" "webhooks" {
  name         = "web"
  namespace_id = aws_service_discovery_http_namespace.webhooks.id
}

resource "aws_service_discovery_instance" "opsrabbit" {
  service_id  = aws_service_discovery_service.webhooks.id
  instance_id = var.instance_id
  attributes = {
    AWS_INSTANCE_IPV4 = data.aws_instance.opsrabbit.private_ip
    AWS_INSTANCE_PORT = tostring(var.target_port)
  }
  depends_on = [
    aws_network_interface_sg_attachment.target,
    aws_vpc_security_group_ingress_rule.target,
    aws_vpc_security_group_egress_rule.target,
  ]
}

resource "aws_apigatewayv2_api" "webhooks" {
  name                         = var.name
  protocol_type                = "HTTP"
  disable_execute_api_endpoint = true
}

resource "aws_apigatewayv2_integration" "webhooks" {
  api_id                 = aws_apigatewayv2_api.webhooks.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_service_discovery_service.webhooks.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.webhooks.id
  payload_format_version = "1.0"
  request_parameters = {
    "overwrite:path" = "$request.path"
  }
  dynamic "tls_config" {
    for_each = var.target_tls_server_name == null ? [] : [var.target_tls_server_name]
    content {
      server_name_to_verify = tls_config.value
    }
  }

  depends_on = [aws_service_discovery_instance.opsrabbit]
}

resource "aws_apigatewayv2_route" "webhooks" {
  api_id             = aws_apigatewayv2_api.webhooks.id
  route_key          = "ANY /webhooks/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.webhooks.id}"
  authorization_type = "NONE"
}

resource "aws_apigatewayv2_stage" "webhooks" {
  api_id      = aws_apigatewayv2_api.webhooks.id
  name        = "$default"
  auto_deploy = true
  depends_on  = [aws_apigatewayv2_route.webhooks]
}

resource "aws_apigatewayv2_domain_name" "webhooks" {
  domain_name = var.opsrabbit_hostname

  domain_name_configuration {
    certificate_arn = var.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "webhooks" {
  api_id      = aws_apigatewayv2_api.webhooks.id
  domain_name = aws_apigatewayv2_domain_name.webhooks.id
  stage       = aws_apigatewayv2_stage.webhooks.name
}

resource "aws_route53_record" "webhooks" {
  count   = var.route53_zone_id == null ? 0 : 1
  zone_id = var.route53_zone_id
  name    = var.opsrabbit_hostname
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.webhooks.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.webhooks.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }

  depends_on = [aws_apigatewayv2_api_mapping.webhooks]
}
