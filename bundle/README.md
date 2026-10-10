# OpsRabbit AWS Image-Only Installer

This bundle deploys the core OpsRabbit stack and its OpenSandbox lifecycle service without copying application source code to the server. It contains only the installer, operations helper, runtime configuration, and image-only Compose manifest.

## Requirements

- Ubuntu Server 24.04 LTS or 26.04 LTS, or Debian 13
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

It configures Docker's official stable apt repository and installs or upgrades Docker Engine, Buildx, and Compose to that repository's latest candidate. When migrating from distribution-provided Docker packages, their removal can briefly interrupt running containers, but Docker data in `/var/lib/docker` is preserved. It also installs the official AWS CLI v2 bundle when `aws` is unavailable, creates the deployment user, generates persistent application and OpenSandbox secrets, logs in to ECR, pre-pulls the sandbox image, starts the services, and checks backend, web, and OpenSandbox health. On Ubuntu hosts enforcing restricted unprivileged user namespaces, it uses Ubuntu's packaged Bubblewrap profile when available and otherwise atomically installs the bundled compatibility profile. It does not disable the host-wide restriction or require a reboot. This also removes an unchanged conflicting fallback left by installer `v1.3.0` on Ubuntu 26.04.

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

ECR login uses a temporary Docker configuration directory. The short-lived ECR authorization token is removed after the command instead of being retained unencrypted in the deployment user's normal Docker configuration.

Configuration is stored at `/opt/opsrabbit/.env` by default. Back it up securely. Never regenerate `OPSRABBIT_NODE_ENCRYPTION_KEY`; doing so makes previously stored encrypted credentials unreadable.

Persistent data is held in Docker named volumes. Back up PostgreSQL, the OpsRabbit data volume, and the `opensandbox-state` lifecycle database before upgrades.

## Enable sandbox execution

The installer starts OpenSandbox but does not silently enable command sandboxing in the application. In **Configuration → Sandbox**, select the OpenSandbox provider and use:

- endpoint: `http://opensandbox-server:8080`
- image: the `OPSRABBIT_SANDBOX_IMAGE` value from `/opt/opsrabbit/.env`
- API key: the `OPENSANDBOX_SERVER_API_KEY` value from `/opt/opsrabbit/.env`

Use session or agent scope, keep worker splitting disabled, and use the workspace-only filesystem policy with deny-all networking for the strict default. Run one controlled command after enabling the provider and confirm that it succeeds.

The updated source bundle uses sandbox host-port pool `20000-29999` (10,000 ports). The currently published `v1.3.2` installer still uses `40000-41000`; installations from that release need the migration below before using the new range. Check existing host listeners, Docker port bindings, and `sysctl net.ipv4.ip_local_port_range` before using it. The new pool avoids Linux's usual `32768-60999` ephemeral range and reduces collisions, but does not eliminate upstream sandbox port-allocation races.

For an existing installation using `40000-41000`, update only `port_range_min` and `port_range_max` in `/opt/opsrabbit/opensandbox-config.toml`, preserving other settings. Apply your existing trusted-network restrictions to the new range, then run `cd /opt/opsrabbit && docker compose up -d --no-deps --force-recreate --wait opensandbox-server`. Keep the old range protected until existing sandboxes retire; their ports remain unchanged. Preserve `opensandbox-state` and allow a brief lifecycle/proxy interruption during recreation. No image rebuild is required.

## OpenSandbox 1.1.1 upgrade

The source bundle pins the server, execd, and egress images to the digests in the [official OpenSandbox 1.1.1 release manifest](https://github.com/opensandbox-group/OpenSandbox/blob/release-1.1.1/docs/releases/1.1.1.yaml). This includes the upstream private-procfs compatibility fix needed by the workspace-only browser. These are digest pins, not a claim of verified image signatures or attestations. Published installer `v1.3.2` remains unchanged and contains the older provider images.

Pair this bundle with a backend image containing [OpsRabbit PR #914](https://github.com/applied-ai-consulting/gaurav-exp/pull/914), including its SDK 1.1.1 byte-range file-download fix. Do not upgrade the provider independently of that backend fix.

For an existing deployment:

1. Back up the persistent data and configuration described above, disable sandbox execution, and let existing managed sandboxes retire.
2. Replace only `opensandbox-server.image` in the deployed `docker-compose.yml` with the pin in [the source Compose file](docker-compose.yml). Replace only `runtime.execd_image` and `egress.image` in the deployed `opensandbox-config.toml` with the pins in [the source runtime configuration](opensandbox-config.toml). Preserve all other settings, `.env`, volumes, port restrictions, and AppArmor configuration. Do not rerun the installer to replace customized configuration.
3. Set `OPSRABBIT_DAEMON_IMAGE` in `.env` to the backend image containing the matching fix, then run `opsrabbitctl update`. It does not download new Compose or TOML files; step 2 is required. The helper preserves daemon-first shutdown and reconnects the lifecycle server to Docker's runtime bridge.
4. Validate health, then enable sandboxing for a controlled thread and check workspace commands, binary/empty file reads, permitted network access, and browser open → snapshot → close before restoring normal sandbox traffic.

The provider upgrade itself does not require rebuilding the OpsRabbit sandbox workload image. Existing sandbox containers retain their old execd/egress runtime until replaced. Ubuntu AppArmor/user-namespace setup is unchanged; this update does not disable host restrictions or require a reboot.

## Security notes

- PostgreSQL and the backend host port bind only to `127.0.0.1`.
- The web port binds publicly by default. Restrict it with a firewall or place an HTTPS reverse proxy/load balancer in front of it.
- Membership in the Docker group is effectively root access.
- The daemon mounts the Docker socket because existing admin-only plugin lifecycle features manage sibling containers. Protect OpsRabbit admin access accordingly.
- The OpenSandbox server also mounts the Docker socket and is host-adjacent infrastructure. Its lifecycle API binds only to loopback, while dynamically created sandbox ports use the configured host range: `20000-29999` in the updated source bundle, or `40000-41000` in release `v1.3.2` until migrated. Deny the active range (both during migration) from untrusted networks with the cloud firewall/security group and Docker-aware forwarding policy before enabling sandbox execution.
- Bubblewrap AppArmor compatibility is configured only when `kernel.apparmor_restrict_unprivileged_userns=1`. An operating-system profile is preferred when available, as it is on Ubuntu 26.04; hosts without one receive the bundled fallback. The restriction remains enabled, and the selected profile applies to every `/usr/bin/bwrap` caller on the host. Validate other local Bubblewrap workloads on a shared host.
- The included Compose file serves HTTP. Terminate production TLS at a reverse proxy or load balancer and set the public origin to its HTTPS URL.
- Keep SSH key-only, restrict administration sources, and do not expose ports 54329 or 8384 publicly.

## Re-running the installer

The installer preserves an existing `.env` so that application secrets are not rotated accidentally. Upgrading from an older installer adds only missing OpenSandbox settings and generates its API key once. To change image tags or the public URL, edit `.env` deliberately and run:

```bash
opsrabbitctl update
```
