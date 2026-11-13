# Operating notes

## Verify after deployment

Use a disposable inbound with authentication configured and confirm the following:

- A valid authenticated webhook arrives at the intended inbound and its delivery is visible in OpsRabbit.
- For a token-protected inbound, confirm OpsRabbit rejects a missing, blank, wrong or different inbound's token and processes no event.
- Requests to the UI, `/api/health`, or the bare `/webhooks` path receive a gateway 404. The default `execute-api` endpoint rejects requests.
- The EC2 web listener stays reachable from its intended private clients. Review existing instance security groups and the host firewall for any direct public access. The added security group allows the web port from the VPC Link security group.

Run a private `/api/health` monitor from an existing trusted monitoring client if you need the equivalent health signal to the ALB probe. Cloud Map holds a registration and this stack does not configure active health checks or failover. API Gateway may take a few minutes to recreate VPC Link interfaces after [60 days without traffic](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-vpc-links-v2.html).

## Replace or remove the target

When replacing EC2, update `instance_id` and run Terraform plan and apply. Terraform reads the primary private IP and reconciles the registration and security group attachment. Allow for interrupted deliveries while replacing the single target. Verify a successful authenticated delivery afterward.

To migrate an existing ALB hostname, test this stack on a separate hostname first. Coordinate the DNS cutover with the owner of the existing record. Manage each DNS record from a single Terraform state.

Destroying the stack removes the managed DNS alias, API, VPC Link, Cloud Map registration and dedicated network grant. Remove any externally managed DNS record separately. The existing instance, VPC, certificate and hosted zone are customer resources.

## Logs, state and cost

API Gateway access logging is disabled. Terraform state and Cloud Map store infrastructure configuration and the private target address. Restrict state access and manage retention, backups and legal holds in your state backend. Destroy removes the live registration. Historical state versions follow the backend's policy.

The VPC Link has no separate fee. Budget for HTTP API calls, data transfer, and Cloud Map registration and discovery calls. See [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/) and [Cloud Map pricing](https://aws.amazon.com/cloud-map/pricing/).

## Local checks

Run `terraform fmt -check -recursive`, `terraform validate`, and `terraform test` with Terraform 1.7 or later. The tests use a mock AWS provider.
