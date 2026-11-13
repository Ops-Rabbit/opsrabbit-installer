mock_provider "aws" {
  mock_data "aws_instance" {
    defaults = {
      subnet_id            = "subnet-instance"
      network_interface_id = "eni-example"
      private_ip           = "10.0.2.15"
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      vpc_id = "vpc-example"
    }
  }
}

variables {
  aws_region          = "us-east-1"
  vpc_id              = "vpc-example"
  vpc_link_subnet_ids = ["subnet-link"]
  instance_id         = "i-0123456789abcdef0"
  certificate_arn     = "arn:aws:acm:us-east-1:123456789012:certificate/01234567-89ab-cdef-0123-456789abcdef"
  opsrabbit_hostname  = "hooks.example.com"
}

run "webhook_only_custom_domain" {
  command = plan

  assert {
    condition = (
      aws_apigatewayv2_api.webhooks.disable_execute_api_endpoint &&
      aws_apigatewayv2_route.webhooks.route_key == "ANY /webhooks/{proxy+}" &&
      aws_apigatewayv2_route.webhooks.authorization_type == "NONE"
    )
    error_message = "The custom-domain webhook route should forward requests for OpsRabbit to authenticate."
  }

  assert {
    condition = (
      aws_apigatewayv2_integration.webhooks.connection_type == "VPC_LINK" &&
      length(aws_apigatewayv2_integration.webhooks.tls_config) == 0 &&
      aws_apigatewayv2_integration.webhooks.request_parameters["overwrite:path"] == "$request.path" &&
      aws_service_discovery_instance.opsrabbit.attributes["AWS_INSTANCE_IPV4"] == "10.0.2.15" &&
      aws_service_discovery_instance.opsrabbit.attributes["AWS_INSTANCE_PORT"] == "3000" &&
      length(aws_route53_record.webhooks) == 0
    )
    error_message = "Forward the original path privately to the registered web port and leave DNS optional."
  }
}

run "custom_tls_port_and_dns" {
  command = plan

  variables {
    target_port            = 443
    target_tls_server_name = "sre.example.com"
    route53_zone_id        = "Z123EXAMPLE"
  }

  assert {
    condition = (
      aws_service_discovery_instance.opsrabbit.attributes["AWS_INSTANCE_PORT"] == "443" &&
      aws_vpc_security_group_ingress_rule.target.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.target.to_port == 443 &&
      aws_vpc_security_group_egress_rule.target.from_port == 443 &&
      aws_vpc_security_group_egress_rule.target.to_port == 443 &&
      one(aws_apigatewayv2_integration.webhooks.tls_config).server_name_to_verify == "sre.example.com" &&
      aws_route53_record.webhooks[0].name == "hooks.example.com"
    )
    error_message = "The HTTPS target should verify the configured certificate name, scope both network rules to the configured port, and use the webhook hostname for DNS."
  }
}

run "reject_mismatched_vpc" {
  command = plan

  variables {
    vpc_id = "vpc-other"
  }

  expect_failures = [aws_apigatewayv2_vpc_link.webhooks]
}
