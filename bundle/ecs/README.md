# Amazon ECS deployment for existing OpsRabbit images

This directory contains starter assets for an **ECS/Fargate** deployment path.  
They are designed to be used with the same Marketplace-hosted container images
you already use for the Compose flow.

What’s included:

- `opsrabbit-ecs-fargate.yaml` — ECS-focused CloudFormation template
- `opsrabbit-ecs.template.env` — environment placeholder values for the ECS launch

The existing Compose installer and assets remain unchanged.

## Quick start

1. Build an `.env` file from the template and set:
   - `OPSRABBIT_DAEMON_IMAGE`
   - `OPSRABBIT_WEB_IMAGE`
   - `OPSRABBIT_NODE_DATABASE_URL`
   - `BETTER_AUTH_SECRET`
   - `OPSRABBIT_NODE_ENCRYPTION_KEY`
   - `OPSRABBIT_WEB_ORIGIN`
   - `OPSRABBIT_NODE_BASE_URL`
   - Optional production hardening params:
     - `UseHttps` (`true|false`)
     - `CertificateArn` (required when `UseHttps=true`)
     - `AllowedEgressCidr` (default `0.0.0.0/0`)
     - `DatabaseSecurityGroupId` (optional DB SG for egress on 5432)

2. Create required AWS resources:

   - ECS Cluster
   - VPC and subnets (public + private)
   - Security groups
   - ALB (public)
   - Postgres-compatible database endpoint reachable from ECS tasks

3. Deploy:

   ```bash
   # Use this simple command only for non-sensitive test environments.
   aws cloudformation deploy \
     --template-file bundle/ecs/opsrabbit-ecs-fargate.yaml \
     --stack-name opsrabbit-ecs \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides $(cat bundle/ecs/opsrabbit-ecs.template.env | xargs)
   ```

   For production, avoid passing secrets in command arguments. Instead copy and edit the JSON example and pass it via `--parameters`:

   ```bash
   cp bundle/ecs/opsrabbit-ecs.parameters.example.json bundle/ecs/opsrabbit-ecs.parameters.json

   aws cloudformation create-stack \
     --stack-name opsrabbit-ecs \
     --template-body file://bundle/ecs/opsrabbit-ecs-fargate.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameters file://bundle/ecs/opsrabbit-ecs.parameters.json
   ```

   To expose HTTPS:

   - Set `UseHttps=true`
   - Set `CertificateArn` to an ACM certificate ARN in the same region as the stack
   - Ensure `OPSRABBIT_WEB_ORIGIN` and `OPSRABBIT_NODE_BASE_URL` use `https://...`

4. Open the ALB DNS name from stack outputs and set `OPSRABBIT_WEB_ORIGIN` to that URL.

## Important notes

- This is a reference template. You should wire Secrets Manager or SSM for secrets in production.
- Data-only volumes for `/home/opsbot/.opsrabbit` and `/home/opsbot/.agent-browser` are currently
  ephemeral in this starter. For durability, add EFS and mount points in your own fork.
- Outbound ECS task egress is broad in this starter template (`1024-65535` to `0.0.0.0/0`). Tighten it for production
  to only required destinations (ECR, DB, and required AWS endpoints).
- In this version, outbound HTTPS egress is limited via `AllowedEgressCidr` (default `0.0.0.0/0`) and DB egress can be narrowed by
  setting `DatabaseSecurityGroupId`.
- Post-deploy validation is the same: backend at `/health`, web at `/`.
- Compose install script, `install.sh`, and existing `.env` conventions are untouched.
