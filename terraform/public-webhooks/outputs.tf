output "webhook_base_url" {
  value = "https://${var.opsrabbit_hostname}/webhooks"
}

output "alb_dns_name" {
  value = aws_lb.webhooks.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.webhooks.arn
}

output "instance_private_ip" {
  description = "Primary private IPv4 used by the ALB instance target."
  value       = data.aws_instance.opsrabbit.private_ip
}
