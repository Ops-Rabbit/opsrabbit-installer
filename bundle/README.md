# OpsRabbit AWS Image-Only Installer

This bundle deploys the core OpsRabbit stack without copying application source code to the server. It contains only an installer, an operations helper, and an image-only Compose manifest.

## Requirements

- Debian or Ubuntu server
- `root` or passwordless `sudo` for the initial installation
- Network access to the configured Amazon ECR registry and public container registries
- ECR pull permissions for both OpsRabbit images
- An EC2 instance role, existing AWS CLI credentials, or an AWS access key
- DNS/firewall configuration appropriate for the chosen public URL

The AWS identity needs at least:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
```

In a tighter IAM policy, keep `ecr:GetAuthorizationToken` on `*` and scope the other actions to the two repository ARNs.

## Install

Copy the archive to the server, then run:

```bash
tar -xzf opsrabbit-aws-image-bundle.tar.gz
cd opsrabbit-aws-image-bundle
sudo ./install.sh
```

The installer asks for:

- deployment user and directory
- AWS region and ECR registry
- fully qualified backend and web image names, including tags
- public URL and web port
- AWS authentication method

It then installs missing prerequisites, creates the deployment user, generates persistent application secrets, logs in to ECR, pulls the images, starts the services, and checks backend and web health.

Use immutable image tags or digests for production rather than `latest`.

## AWS authentication

The recommended EC2 option is an instance profile with only the ECR pull permissions above. No long-lived AWS credential is then stored on the host.

The stored-access-key option writes standard AWS CLI files beneath the deployment user's home with directory mode `0700` and file mode `0600`. Prefer an instance role when available.

The preconfigured option expects `aws sts get-caller-identity` to work as the deployment user before installation continues.

## Operations

Run these as the deployment user:

```bash
opsrabbitctl status
opsrabbitctl logs
opsrabbitctl logs daemon
opsrabbitctl health
opsrabbitctl update
opsrabbitctl stop
opsrabbitctl start
```

`opsrabbitctl update` logs in to ECR, pulls the configured image tags, recreates changed containers, waits for health checks, and prints status.

Configuration is stored at `/opt/opsrabbit/.env` by default. Back it up securely. Never regenerate `OPSRABBIT_NODE_ENCRYPTION_KEY`; doing so makes previously stored encrypted credentials unreadable.

Persistent data is held in Docker named volumes. Back up PostgreSQL and the OpsRabbit data volume before upgrades.

## Security notes

- PostgreSQL and the backend host port bind only to `127.0.0.1`.
- The web port binds publicly by default. Restrict it with a firewall or place an HTTPS reverse proxy/load balancer in front of it.
- Membership in the Docker group is effectively root access.
- The daemon mounts the Docker socket because existing admin-only plugin lifecycle features manage sibling containers. Protect OpsRabbit admin access accordingly.
- The included Compose file serves HTTP. Terminate production TLS at a reverse proxy or load balancer and set the public origin to its HTTPS URL.
- Keep SSH key-only, restrict administration sources, and do not expose ports 54329 or 8384 publicly.

## Re-running the installer

The installer preserves an existing `.env` so that application secrets are not rotated accidentally. To change image tags or the public URL, edit `.env` deliberately and run:

```bash
opsrabbitctl update
```

