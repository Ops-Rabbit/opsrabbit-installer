# OpsRabbit AWS Image-Only Installer

This bundle deploys the core OpsRabbit stack without copying application source code to the server. It contains only an installer, an operations helper, and an image-only Compose manifest.

## Quick install

Install the tagged `v1.2.0` release on a Debian or Ubuntu host:

```bash
curl -fsSL https://github.com/Ops-Rabbit/opsrabbit-installer/releases/download/v1.2.0/install.sh | sudo bash
```

This URL points to an immutable GitHub Release asset, not the mutable `main` branch. The release bootstrap is pinned internally to the same `v1.2.0` tag. It downloads that release's archive and published SHA-256 file, verifies the archive, and only then starts the interactive installer. Review `install.sh` before piping it to a privileged shell if your security policy requires it.

To install another version, replace `v1.2.0` in the URL with the required release tag.

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

For a normal EC2 installation with a working instance role, the installer asks only for:

- the public OpsRabbit URL
- confirmation before changing the host

The deployment user (`opsrabbit`), directory (`/opt/opsrabbit`), AWS region (`us-east-1`), ECR registry, image repositories, `latestv2` deployment tag, and web port (`3000`) use the OpsRabbit defaults. AWS access credentials are requested only if neither an EC2 instance role nor existing AWS CLI credentials are available to the deployment user.

Advanced deployments can override defaults with `OPSRABBIT_INSTALL_USER`, `OPSRABBIT_INSTALL_DIR`, `OPSRABBIT_AWS_REGION`, `OPSRABBIT_ECR_REGISTRY`, `OPSRABBIT_DAEMON_IMAGE`, `OPSRABBIT_WEB_IMAGE`, or `OPSRABBIT_WEB_PORT`.

It then installs missing prerequisites, creates the deployment user, generates persistent application secrets, logs in to ECR, pulls the images, starts the services, and checks backend and web health.

Use immutable image tags or digests for production rather than `latest`.

## AWS authentication

The installer automatically uses an EC2 instance profile or existing AWS CLI identity when one is available to the deployment user. An instance profile with only the ECR pull permissions above is recommended because no long-lived AWS credential is stored on the host.

The stored-access-key option writes standard AWS CLI files beneath the deployment user's home with directory mode `0700` and file mode `0600`. Prefer an instance role when available.

When no working identity is detected, the installer requests a least-privilege access key and validates it before pulling images.

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
