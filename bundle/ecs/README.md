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

2. Create required AWS resources:

   - ECS Cluster
   - VPC and subnets (public + private)
   - Security groups
   - ALB (public)
   - Postgres-compatible database endpoint reachable from ECS tasks

3. Deploy:

   ```bash
   aws cloudformation deploy \
     --template-file bundle/ecs/opsrabbit-ecs-fargate.yaml \
     --stack-name opsrabbit-ecs \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides $(cat bundle/ecs/opsrabbit-ecs.template.env | xargs)
   ```

4. Open the ALB DNS name from stack outputs and set `OPSRABBIT_WEB_ORIGIN` to that URL.

## Important notes

- This is a reference template. You should wire Secrets Manager or SSM for secrets in production.
- Data-only volumes for `/home/opsbot/.opsrabbit` and `/home/opsbot/.agent-browser` are currently
  ephemeral in this starter. For durability, add EFS and mount points in your own fork.
- Post-deploy validation is the same: backend at `/health`, web at `/`.
- Compose install script, `install.sh`, and existing `.env` conventions are untouched.
