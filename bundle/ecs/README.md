# OpsRabbit on Amazon ECS Fargate

This directory provides the CloudFormation deployment resource for the OpsRabbit AWS Marketplace container delivery option. It runs the Marketplace-hosted daemon and web images in one Fargate task and uses an existing Amazon RDS for PostgreSQL database.

The Docker Compose installer remains a separate deployment option and is not changed by this stack.

## Architecture

The stack creates:

- An ECS cluster, Fargate service, and task definition
- An internet-facing Application Load Balancer with HTTPS only
- An ECS task execution role for Marketplace ECR pulls, CloudWatch Logs, and one Secrets Manager secret
- An empty task role to which customers can add permissions required by enabled integrations
- CloudWatch log groups with configurable retention and ECS Container Insights
- An encrypted EFS file system with automatic backups and access points for all persistent daemon paths
- Security groups restricted to ALB-to-service, service-to-RDS, service-to-EFS, and configurable HTTPS egress

The customer supplies:

- A VPC with two public and exactly two private subnets in different Availability Zones
- Private-subnet access to ECR, S3, CloudWatch Logs, Secrets Manager, and required external services through a NAT gateway or VPC endpoints
- An existing RDS for PostgreSQL database and its security group
- An issued ACM certificate and public DNS name
- A Secrets Manager secret containing the application configuration
- The two immutable image URIs shown after subscribing to the AWS Marketplace product

The EFS file system has `DeletionPolicy: Retain` and remains after stack deletion. RDS is external to the stack and is never deleted by it. CloudWatch log groups and other stack-created resources follow normal CloudFormation deletion behavior.

## ECS-safe runtime profile

This delivery option is intentionally Docker-free:

- The daemon has no Docker socket, Docker daemon, or privileged container access.
- Trusted packaged OpsRabbit plugins continue to use the normal in-process plugin runtime.
- Turn workers use the product's `local-process` runner provider, which is the default for a new installation.
- The Docker worker provider and actions that manage Docker or Compose workloads are not supported in this delivery option.
- Long-running companion services must be declared as fixed CloudFormation-managed ECS services rather than launched dynamically by the application.
- Customer-uploaded or untrusted plugin isolation is not part of this ECS delivery option.

Do not change the worker runner provider to `docker` on ECS. A deployment migrated from an existing database must be switched to `local-process` before the ECS service is started. This profile does not require Docker permissions in either ECS IAM role.

## Product release checks

Complete these checks before submitting this delivery option to AWS Marketplace:

- Push the daemon and web images, including every required image dependency, to repositories created for this product in the AWS Marketplace console.
- Use release-specific immutable tags or digests. Do not publish seller-account ECR, Docker Hub, or other external image references in the delivery instructions.
- Confirm both images run as a non-root user and contain no known vulnerabilities, malware, hardcoded secrets, unsupported architectures, or end-of-life operating-system packages.
- Confirm the image user has UID and GID `1000`, which the EFS access points enforce. Change the access-point identity only if the published image uses a different non-root identity.
- Validate database migrations and application startup against the supported RDS PostgreSQL version, with `pgvector` enabled when required by the product version.
- Validate multi-task behavior before increasing `DesiredCount` above 1.
- Verify a fresh production installation reports `local-process` as its worker runner provider.

## OpsRabbit offline license

OpsRabbit uses its own offline signed license file. It does not call AWS License Manager or AWS Marketplace Metering Service from this ECS deployment, and the task role intentionally has no permissions for those services.

After the first successful deployment:

1. Sign in as a deployment administrator.
2. Open the OpsRabbit Status page and obtain the generated deployment ID.
3. Have an OpsRabbit license issued for that deployment ID.
4. Apply the signed `.license` file from the Status page.
5. Confirm the Status page reports the expected entitlements and validity period.

The backend stores the signed license at `/home/opsbot/.opsrabbit/license/opsrabbit.license` and the stable deployment identity at `/home/opsbot/.opsrabbit/license/deployment.json`. The encrypted EFS `opsrabbit-data` access point persists both files across ECS task replacements and stack updates. Keep the private signing key outside customer deployments and container images.

Missing, invalid, not-yet-valid, or expired licenses leave the base administrative recovery surfaces available while licensed OpsRabbit capabilities remain disabled according to the product's fail-closed entitlement policy.

## Prerequisites

1. Subscribe to the product and record the daemon and web image URIs from the AWS Marketplace fulfillment page.
2. Create or select a VPC with two public subnets and exactly two private subnets across two Availability Zones.
3. Give the private subnets outbound connectivity using a NAT gateway, or create the required VPC endpoints. ECR image pulls normally require ECR API, ECR DKR, and an S3 gateway endpoint; this stack also needs CloudWatch Logs and Secrets Manager access.
4. Create an RDS for PostgreSQL database in the VPC. Enable storage encryption, automated backups, deletion protection as appropriate, and PostgreSQL TLS. Attach a dedicated security group. The stack adds inbound port 5432 from the ECS task security group.
5. Request or import an ACM certificate in the deployment region for the public DNS name and wait until its status is `ISSUED`.
6. Create the application secret described below.

The identity deploying the stack needs CloudFormation permissions plus permission to create and manage ECS, Elastic Load Balancing, EC2 security-group rules, EFS, CloudWatch Logs, and IAM roles. Because the template creates IAM roles, deployment requires `CAPABILITY_IAM`.

## Create the application secret

Create three cryptographically random values. Preserve `encryptionKey` across upgrades and disaster recovery; changing it makes previously encrypted application credentials unreadable.

The `databaseUrl` should use the RDS endpoint, require TLS, and percent-encode reserved characters in the username or password. For example:

```text
postgresql://opsrabbit:ENCODED_PASSWORD@database.example.region.rds.amazonaws.com:5432/opsrabbit?sslmode=require
```

Create the JSON secret without placing values in shell history:

```bash
aws secretsmanager create-secret \
  --name opsrabbit/application \
  --secret-string file://opsrabbit-application-secret.json
```

The local JSON file must have exactly these keys:

```json
{
  "databaseUrl": "postgresql://...",
  "betterAuthSecret": "generated-random-value",
  "encryptionKey": "generated-random-value"
}
```

Delete the local secret file securely after creation according to your organization's secret-handling policy. If the secret uses a customer-managed KMS key, grant the generated ECS task execution role `kms:Decrypt` on that key before starting the service.

## Deploy

Copy the parameter example to an untracked file and replace every placeholder:

```bash
cp bundle/ecs/opsrabbit-ecs.parameters.example.json bundle/ecs/opsrabbit-ecs.parameters.json

aws cloudformation create-stack \
  --stack-name opsrabbit \
  --template-body file://bundle/ecs/opsrabbit-ecs-fargate.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters file://bundle/ecs/opsrabbit-ecs.parameters.json
```

Wait for stack creation:

```bash
aws cloudformation wait stack-create-complete --stack-name opsrabbit
aws cloudformation describe-stacks --stack-name opsrabbit --query 'Stacks[0].Outputs'
```

Create a Route 53 alias, or an equivalent DNS CNAME where supported, from `PublicDomainName` to the `WebLoadBalancerDnsName` output. Then open the `WebUrl` output. The certificate must cover the public name; do not browse directly to the ALB hostname and expect certificate validation to succeed.

## Network flow

- Client to ALB: HTTPS 443 from `AllowedIngressCidr`
- ALB to web container: HTTP 80, restricted by security-group reference
- Web to daemon: loopback TCP 8384 inside the same Fargate task
- Daemon to RDS: TCP 5432, restricted by security-group reference
- Task to EFS: encrypted NFS TCP 2049, restricted by security-group reference
- Task outbound: HTTPS 443 to `AllowedHttpsEgressCidr`

The daemon port is never exposed through the ALB. The database is not exposed publicly by this template. Start with a restricted `AllowedIngressCidr`; use `0.0.0.0/0` only when the application is intentionally public and application authentication is ready.

## IAM role purpose

- Task execution role: used by ECS before container startup to pull Marketplace ECR images, create log streams, publish container logs, and read `ApplicationSecretArn`.
- Task role: used by the running application. It starts without AWS API permissions. Add narrowly scoped permissions only for customer-enabled integrations. OpsRabbit offline-license validation requires no AWS IAM permission.

The template never requests access keys. Containers obtain temporary credentials from ECS task-role metadata.

## Encryption and data lifecycle

- Public traffic terminates with TLS at the ALB using ACM.
- Application-to-RDS TLS is controlled by `databaseUrl`; use `sslmode=require` or the stronger verification mode supported by your certificate setup.
- EFS data is encrypted at rest and in transit, and automatic EFS backups are enabled.
- Secrets are retrieved from Secrets Manager and are not stored as plaintext CloudFormation parameters or ECS environment values.
- The signed OpsRabbit license and deployment identity are persisted under the encrypted EFS-backed application data directory.
- CloudWatch logs are retained for `LogRetentionDays`; avoid logging prompts, credentials, or secret values.
- The encrypted EFS file system is retained when the stack is deleted. Delete it and its backups separately only after preserving required customer data.
- RDS retention, backups, snapshots, and deletion remain under the customer's existing database policy.

## Operations and upgrades

Check service health and logs:

```bash
aws ecs describe-services --cluster opsrabbit-cluster --services opsrabbit-service
aws logs tail /ecs/opsrabbit/daemon --follow
aws logs tail /ecs/opsrabbit/web --follow
```

For upgrades, back up RDS and verify EFS backup status, replace both image parameters with the new Marketplace version digests, and update the stack. The ECS deployment circuit breaker rolls back a failed service deployment, but it cannot reverse a database migration. Follow the product release notes for migration compatibility and rollback requirements.

Do not rotate `encryptionKey` during routine upgrades. Secret updates require a new ECS deployment so replacement tasks retrieve the new secret version.

## AWS service costs and quotas

Customers pay separately for Fargate CPU and memory, the Application Load Balancer and capacity units, EFS storage and backups, CloudWatch Logs ingestion and retention, Secrets Manager, RDS, data transfer, and NAT gateways or VPC endpoints. Review current regional pricing before deployment.

Check quotas for Fargate tasks, ENIs and IP addresses, ALBs, target groups, security groups and rules, EFS file systems/access points, CloudWatch log groups, and RDS capacity. Each running task consumes a private-subnet IP address. Request quota increases before production rollout when required.

## Validation and troubleshooting

- `ResourceInitializationError` while pulling images: verify subscription, Marketplace image URI, execution-role ECR permissions, and NAT/VPC endpoint routing.
- Secret retrieval failure: verify the secret ARN, required JSON keys, execution-role access, region, and KMS permissions.
- EFS mount failure: verify both private subnet Availability Zones, mount targets, NFS security-group rules, UID/GID compatibility, and network ACLs.
- RDS connection failure: verify the URL, TLS parameters, database availability, RDS security group, route tables, and network ACLs.
- ALB target unhealthy: inspect both CloudWatch log groups and ECS container health. The web container waits for the daemon health check.
- Browser certificate error: verify DNS points to the output ALB and the ACM certificate covers `PublicDomainName`.
- Docker worker error: verify the system worker runner provider is `local-process`; Docker is intentionally unavailable in the ECS-safe profile.

Before publishing a version, run `cfn-lint bundle/ecs/opsrabbit-ecs-fargate.yaml` and deploy it in an allow-listed test buyer account using the exact Marketplace images and pricing integration intended for release.
