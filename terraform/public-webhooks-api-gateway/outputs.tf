output "webhook_base_url" {
  value = "https://${var.opsrabbit_hostname}/webhooks"
}

output "api_gateway_dns_name" {
  description = "Regional DNS target for the webhook hostname."
  value       = aws_apigatewayv2_domain_name.webhooks.domain_name_configuration[0].target_domain_name
}

output "api_gateway_hosted_zone_id" {
  description = "Regional hosted zone ID for an externally managed Route 53 alias."
  value       = aws_apigatewayv2_domain_name.webhooks.domain_name_configuration[0].hosted_zone_id
}

output "instance_private_ip" {
  value = data.aws_instance.opsrabbit.private_ip
}
