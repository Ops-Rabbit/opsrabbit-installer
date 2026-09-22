# OpsRabbit AWS Image-Only Installer

This bundle deploys the core OpsRabbit stack and its OpenSandbox lifecycle service without copying application source code to the server. It contains only the installer, operations helper, runtime configuration, and image-only Compose manifest.

## Quick install

Install the tagged `v1.3.0` release on a Debian or Ubuntu host:

```bash
curl -fsSL https://github.com/Ops-Rabbit/opsrabbit-installer/releases/download/v1.3.0/install.sh | sudo bash
```

This URL points to an immutable GitHub Release asset, not the mutable `main` branch. The release bootstrap is pinned internally to the same `v1.3.0` tag. It downloads that release's archive and published SHA-256 file, verifies the archive, and only then starts the interactive installer. Review `install.sh` before piping it to a privileged shell if your security policy requires it.

To install another version, replace `v1.3.0` in the URL with the required release tag. Run it from an interactive SSH session; the installer now fails immediately with guidance if no controlling terminal is available.

## Requirements

- Debian or Ubuntu server
- x86-64 CPU architecture
- `root` or passwordless `sudo` for the initial installation
- Network access to the configured Amazon ECR registry and public container registries
- ECR pull permissions for the OpsRabbit backend, web, and sandbox images
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

In a tighter IAM policy, keep `ecr:GetAuthorizationToken` on `*` and scope the other actions to the three repository ARNs.

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

The deployment user (`opsrabbit`), directory (`/opt/opsrabbit`), AWS region (`us-east-1`), ECR registry, backend and web `latestv2` deployment tags, `vg-sandbox:latest` sandbox image, OpenSandbox port (`8080` on loopback), and web port (`3000`) use the OpsRabbit defaults. AWS access credentials are requested only if neither an EC2 instance role nor existing AWS CLI credentials are available to the deployment user.

Advanced deployments can override defaults with `OPSRABBIT_INSTALL_USER`, `OPSRABBIT_INSTALL_DIR`, `OPSRABBIT_AWS_REGION`, `OPSRABBIT_ECR_REGISTRY`, `OPSRABBIT_DAEMON_IMAGE`, `OPSRABBIT_WEB_IMAGE`, `OPSRABBIT_SANDBOX_IMAGE`, `OPENSANDBOX_PORT`, or `OPSRABBIT_WEB_PORT`.

It then installs missing prerequisites, installs the official AWS CLI v2 bundle when `aws` is unavailable, creates the deployment user, generates persistent application and OpenSandbox secrets, logs in to ECR, pre-pulls the sandbox image, starts the services, and checks backend, web, and OpenSandbox health. On Ubuntu hosts enforcing restricted unprivileged user namespaces, it validates and atomically installs the scoped Bubblewrap AppArmor compatibility profile without disabling the host-wide restriction or requiring a reboot.

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

`opsrabbitctl update` logs in to ECR, pre-pulls the configured sandbox image, pulls the service image tags, gracefully stops the backend while OpenSandbox remains available for managed-sandbox cleanup, recreates changed containers, waits for health checks, and prints status. `stop` and `restart` use the same cleanup ordering. `opsrabbitctl health` also verifies OpenSandbox authentication and confirms that the configured sandbox image is present.

Configuration is stored at `/opt/opsrabbit/.env` by default. Back it up securely. Never regenerate `OPSRABBIT_NODE_ENCRYPTION_KEY`; doing so makes previously stored encrypted credentials unreadable.

Persistent data is held in Docker named volumes. Back up PostgreSQL, the OpsRabbit data volume, and the `opensandbox-state` lifecycle database before upgrades.

## Enable sandbox execution

The installer starts OpenSandbox but does not silently enable command sandboxing in the application. In **Configuration → Sandbox**, select the OpenSandbox provider and use:

- endpoint: `http://opensandbox-server:8080`
- image: the `OPSRABBIT_SANDBOX_IMAGE` value from `/opt/opsrabbit/.env`
- API key: the `OPENSANDBOX_SERVER_API_KEY` value from `/opt/opsrabbit/.env`

Use session or agent scope, keep worker splitting disabled, and use the workspace-only filesystem policy with deny-all networking for the strict default. Run one controlled command after enabling the provider and confirm that it succeeds.

## Security notes

- PostgreSQL and the backend host port bind only to `127.0.0.1`.
- The web port binds publicly by default. Restrict it with a firewall or place an HTTPS reverse proxy/load balancer in front of it.
- Membership in the Docker group is effectively root access.
- The daemon mounts the Docker socket because existing admin-only plugin lifecycle features manage sibling containers. Protect OpsRabbit admin access accordingly.
- The OpenSandbox server also mounts the Docker socket and is host-adjacent infrastructure. Its lifecycle API binds only to loopback, while dynamically created sandbox ports use the host range `40000-41000`. Deny that range from untrusted networks with the cloud firewall/security group and Docker-aware forwarding policy before enabling sandbox execution.
- The Bubblewrap AppArmor profile is installed only when `kernel.apparmor_restrict_unprivileged_userns=1`. It leaves that restriction enabled and applies to every `/usr/bin/bwrap` caller on the host. Validate other local Bubblewrap workloads on a shared host.
- The included Compose file serves HTTP. Terminate production TLS at a reverse proxy or load balancer and set the public origin to its HTTPS URL.
- Keep SSH key-only, restrict administration sources, and do not expose ports 54329 or 8384 publicly.

## Re-running the installer

The installer preserves an existing `.env` so that application secrets are not rotated accidentally. Upgrading from an older installer adds only missing OpenSandbox settings and generates its API key once. To change image tags or the public URL, edit `.env` deliberately and run:

```bash
opsrabbitctl update
```
