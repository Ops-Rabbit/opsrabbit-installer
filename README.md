# OpsRabbit AWS Image-Only Installer

This bundle deploys the core OpsRabbit stack and its OpenSandbox lifecycle service without copying application source code to the server. It contains only the installer, operations helper, runtime configuration, and image-only Compose manifest.

## Quick install

Install the tagged `v1.3.4` release on a Debian or Ubuntu host:

```bash
curl -fsSL https://github.com/Ops-Rabbit/opsrabbit-installer/releases/download/v1.3.4/install.sh | sudo bash
```

This URL points to an immutable GitHub Release asset, not the mutable `main` branch. The release bootstrap is pinned internally to the same `v1.3.4` tag. It downloads that release's archive and published SHA-256 file, verifies the archive, and only then starts the interactive installer. Review `install.sh` before piping it to a privileged shell if your security policy requires it.

To install another version, replace `v1.3.4` in the URL with the required release tag. Run it from an interactive SSH session; the installer now fails immediately with guidance if no controlling terminal is available.

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

The installer asks for:

- the public OpsRabbit URL
- confirmation before changing the host
- an explicit AWS authentication method for the private images

The deployment user (`opsrabbit`), directory (`/opt/opsrabbit`), AWS region (`us-east-1`), ECR registry, matched backend/web version tags from one product release, the release-qualified sandbox image, OpenSandbox port (`8080` on loopback), and web port (`3000`) use the OpsRabbit defaults. AWS authentication is explicitly selected even when the machine already has an EC2 role.

Advanced deployments can override defaults with `OPSRABBIT_INSTALL_USER`, `OPSRABBIT_INSTALL_DIR`, `OPSRABBIT_AWS_REGION`, `OPSRABBIT_ECR_REGISTRY`, `OPSRABBIT_DAEMON_IMAGE`, `OPSRABBIT_WEB_IMAGE`, `OPSRABBIT_SANDBOX_IMAGE`, `OPENSANDBOX_PORT`, or `OPSRABBIT_WEB_PORT`.

It configures Docker's official stable apt repository and installs or upgrades Docker Engine, Buildx, and Compose to that repository's latest candidate. When migrating from distribution-provided Docker packages, their removal can briefly interrupt running containers, but Docker data in `/var/lib/docker` is preserved. It also installs the official AWS CLI v2 bundle when `aws` is unavailable, creates the deployment user, generates persistent application and OpenSandbox secrets, logs in to ECR, pre-pulls the sandbox image, starts the services, and checks backend, web, and OpenSandbox health. On Ubuntu hosts enforcing restricted unprivileged user namespaces, it installs the browser-specific AppArmor policy and uses Ubuntu's packaged Bubblewrap policy for ordinary commands when available, otherwise installing the bundled fallback. Policy changes are rolled back if installation fails. It does not disable the host-wide restriction or require a reboot. This also removes an unchanged conflicting fallback left by installer `v1.3.0` on Ubuntu 26.04.

Product releases use immutable version tags. Floating image aliases are not used. Published installer v1.3.4 assets remain unchanged; the versioned-release functionality in this source tree requires a new installer release before use.

## AWS authentication

Choose one of the following during installation:

1. **Sign in with AWS CLI:** open the displayed URL in your browser and enter the authorization code in the server terminal. This uses `aws login --remote` with the managed `opsrabbit-deploy` profile. An existing older AWS CLI must support `aws login`; otherwise update AWS CLI v2 or select temporary credentials.
2. **Enter temporary AWS credentials:** supply your access key, secret key and session token through hidden prompts. The session token is required for temporary credentials. Long-lived access keys can omit the token.
3. **Use this machine's EC2 role:** explicitly opt in only when that role is intended to pull the deployment images. On a client machine, choose your own login or credentials instead.
4. **Use an existing AWS CLI profile:** enter a profile already configured for the deployment user. Profiles belonging to `ubuntu`, `ssm-user` or `root` are not copied. Existing IAM Identity Center profiles can renew through device authorization.

The helper displays the selected AWS account and role/user, logs in to ECR, and checks all three configured image manifests before deployment. All image pulls finish before running services are changed. A successful ECR login alone does not prove image access. Failed selection returns to the installer menu; normal deployment/update commands fail with renewal instructions. The helper clears inherited AWS credentials and provider/endpoint overrides. EC2 metadata is disabled unless the instance-role option was explicitly selected.

The method/profile selection is stored in `/opt/opsrabbit/.aws-auth` with mode `0600`. Temporary credentials are stored separately in the deployment user's `~/.aws/opsrabbit/credentials` with directory mode `0700` and file mode `0600`; they are never written to the application's `.env`. Browser login uses `~/.aws/opsrabbit/config` and AWS CLI's login cache. Existing profiles use that user's standard AWS CLI files. Successful switches away from temporary credentials remove the managed credentials file. AWS CLI owns browser/SSO session expiry and cache management.

For renewal, a new selection, or identity inspection, run from your normal sudo-capable account:

```bash
opsrabbitctl auth login
opsrabbitctl auth configure
opsrabbitctl auth status
```

`auth login` renews the selected browser, temporary-credential or SSO method and checks image access again. Other existing profile types must be renewed through their configured AWS credential provider. Legacy installations without an explicit selection must run `opsrabbitctl auth configure` after upgrading the helper. No manual exports or Linux-user switching are required.

## Operations

Run these from your normal sudo-capable account. The helper requests sudo when necessary and runs as the deployment owner, so AWS login and subsequent commands use the same home directory:

```bash
opsrabbitctl status
opsrabbitctl logs
opsrabbitctl logs daemon
opsrabbitctl health
opsrabbitctl update --backup-confirmed
opsrabbitctl stop
opsrabbitctl start
```

`opsrabbitctl update --backup-confirmed` selects the highest complete stable product release, validates its paired version manifest and selected AWS access, pulls all candidate images, stops web before the backend, waits for the new daemon and workers, then starts and verifies the matched web image. OpenSandbox remains available during backend shutdown for managed-sandbox cleanup. A failed update keeps web stopped and records the pending version for explicit recovery. `stop` and `restart` use the same cleanup ordering. `opsrabbitctl health` also verifies OpenSandbox authentication and confirms that the configured sandbox image is present.

Configuration is stored at `/opt/opsrabbit/.env` by default. Back it up securely. Never regenerate `OPSRABBIT_NODE_ENCRYPTION_KEY`; doing so makes previously stored encrypted credentials unreadable.

Persistent data is held in Docker named volumes. Back up PostgreSQL, the OpsRabbit data volume, and the `opensandbox-state` lifecycle database before upgrades.

## Enable sandbox execution

The installer starts OpenSandbox but does not silently enable command sandboxing in the application. In **Configuration → Sandbox**, select the OpenSandbox provider and use:

- endpoint: `http://opensandbox-server:8080`
- image: the `OPSRABBIT_SANDBOX_IMAGE` value from `/opt/opsrabbit/.env`
- API key: the `OPENSANDBOX_SERVER_API_KEY` value from `/opt/opsrabbit/.env`

Use session or agent scope, keep worker splitting disabled, and use the workspace-only filesystem policy with deny-all networking for the strict default. Run one controlled command after enabling the provider and confirm that it succeeds.

The `v1.3.3` bundle uses sandbox host-port pool `20000-29999` (10,000 ports). The `v1.3.2` installer uses `40000-41000`; installations from that release need the migration below before using the new range. Check existing host listeners, Docker port bindings, and `sysctl net.ipv4.ip_local_port_range` before using it. The new pool avoids Linux's usual `32768-60999` ephemeral range and reduces collisions, but does not eliminate upstream sandbox port-allocation races.

For an existing installation using `40000-41000`, update only `port_range_min` and `port_range_max` in `/opt/opsrabbit/opensandbox-config.toml`, preserving other settings. Apply your existing trusted-network restrictions to the new range, then run `cd /opt/opsrabbit && docker compose up -d --no-deps --force-recreate --wait opensandbox-server`. Keep the old range protected until existing sandboxes retire; their ports remain unchanged. Preserve `opensandbox-state` and allow a brief lifecycle/proxy interruption during recreation. No image rebuild is required.

## OpenSandbox 1.1.1 upgrade

The `v1.3.3` bundle pins the server, execd, and egress images to the digests in the [official OpenSandbox 1.1.1 release manifest](https://github.com/opensandbox-group/OpenSandbox/blob/release-1.1.1/docs/releases/1.1.1.yaml). This includes the upstream private-procfs compatibility fix needed by the workspace-only browser. These are digest pins, not a claim of verified image signatures or attestations. Published installer `v1.3.2` remains unchanged and contains the older provider images.

Pair this bundle with a backend image containing [OpsRabbit PR #914](https://github.com/applied-ai-consulting/gaurav-exp/pull/914), including its SDK 1.1.1 byte-range file-download fix. Do not upgrade the provider independently of that backend fix.

For an existing deployment:

1. Back up the persistent data and configuration described above, disable sandbox execution, and let existing managed sandboxes retire.
2. Replace only `opensandbox-server.image` in the deployed `docker-compose.yml` with the pin in [the source Compose file](bundle/docker-compose.yml). Replace only `runtime.execd_image` and `egress.image` in the deployed `opensandbox-config.toml` with the pins in [the source runtime configuration](bundle/opensandbox-config.toml). Preserve all other settings, `.env`, volumes, port restrictions, and AppArmor configuration. Do not rerun the installer to replace customized configuration.
3. Set `OPSRABBIT_DAEMON_IMAGE` in `.env` to the backend image containing the matching fix, then run `opsrabbitctl update`. It does not download new Compose or TOML files; step 2 is required. The helper preserves daemon-first shutdown and reconnects the lifecycle server to Docker's runtime bridge.
4. Validate health, then enable sandboxing for a controlled thread and check workspace commands, binary/empty file reads, permitted network access, and browser open → snapshot → close before restoring normal sandbox traffic.

The provider upgrade itself does not require rebuilding the OpsRabbit sandbox workload image. Existing sandbox containers retain their old execd/egress runtime until replaced. Ubuntu AppArmor/user-namespace setup is unchanged; this update does not disable host restrictions or require a reboot.

## Browser/AppArmor compatibility upgrade

The `v1.3.3` bundle also carries the browser policy for [OpsRabbit PR #916](https://github.com/applied-ai-consulting/gaurav-exp/pull/916). Published installer `v1.3.2` does not include it. Unlike the provider-only 1.1.1 upgrade above, this browser fix requires a **rebuilt sandbox workload image and matching backend** containing #916. Keep the existing image tags if desired, but verify their new digests contain that fix before upgrading.

On restricted Ubuntu hosts, the bundled root installer installs both required policy layers automatically. For an existing deployment, use the newly downloaded source/release bundle without rerunning its full installer:

1. Disable sandbox execution and allow managed sandboxes to retire. Back up configuration and data as described above.
2. From the new extracted bundle, run `sudo ./scripts/install-opensandbox-apparmor.sh`. This installs `/etc/apparmor.d/opsrabbit-opensandbox-browser`, keeps the packaged Bubblewrap policy when present, and removes only a byte-identical known legacy fallback. It rejects disabled packaged policy or a customized conflicting fallback rather than overwriting it. The script installs **policy only**, not a host browser launcher. Hosts without the restricted-userns setting do not require this policy step.
3. Point `.env` at the matching backend and rebuilt sandbox workload image, or verify those images were published under your existing tags; run `opsrabbitctl update`. It pre-pulls the workload image but does not install host policy. Preserve `.env` secrets and all existing Compose/TOML settings.
4. Start a new controlled thread and verify ordinary commands plus browser open → snapshot → reuse → close. Check `chrome://sandbox` for namespace, PID-namespace and seccomp protections before restoring normal traffic. Existing sandbox containers retain their previous image until retired/recreated.

The workload image must contain the root-owned native Bubblewrap copy at `/opt/opsrabbit-system/bin/browser-bwrap` and immutable Chromium executable at `/opt/opsrabbit-agent-browser/chromium/chrome` on every host. Custom browser images/executables need a matching reviewed host policy on restricted Ubuntu. Do not install the image launcher on the host or disable Chromium's sandbox. Ordinary commands retain their capability-denying policy; standard sandbox containers must retain Docker's normal AppArmor/seccomp confinement. Deliberately unconfined standard containers are unsupported. No host reboot is required.

## Security notes

- PostgreSQL and the backend host port bind only to `127.0.0.1`.
- The web port binds publicly by default. Restrict it with a firewall or place an HTTPS reverse proxy/load balancer in front of it.
- Membership in the Docker group is effectively root access.
- The daemon mounts the Docker socket because existing admin-only plugin lifecycle features manage sibling containers. Protect OpsRabbit admin access accordingly.
- The OpenSandbox server also mounts the Docker socket and is host-adjacent infrastructure. Its lifecycle API binds only to loopback, while dynamically created sandbox ports use the configured host range: `20000-29999` in installer `v1.3.3`, or `40000-41000` in release `v1.3.2` until migrated. Deny the active range (both during migration) from untrusted networks with the cloud firewall/security group and Docker-aware forwarding policy before enabling sandbox execution.
- Bubblewrap AppArmor compatibility is configured only when `kernel.apparmor_restrict_unprivileged_userns=1`. Ordinary `/usr/bin/bwrap` callers retain the packaged or bundled capability-denying policy. A separate image-only browser entrypoint uses capability-denied controllers and the fixed Chromium namespace-capability policy, preserving Chromium's sandbox and the host-wide restriction. Validate other local Bubblewrap workloads on a shared host.
- The included Compose file serves HTTP. Terminate production TLS at a reverse proxy or load balancer and set the public origin to its HTTPS URL.
- Keep SSH key-only, restrict administration sources, and do not expose ports 54329 or 8384 publicly.

## Re-running the installer

The installer preserves an existing `.env` so that application secrets are not rotated accidentally. Use an explicit product version with `opsrabbitctl update --version vX.Y.Z --backup-confirmed` to choose application images; the manifest owns managed image references. Do not edit those references independently.

For a URL-only change, preserve the image pins and edit the relevant URL setting, then recreate the affected service using the installed override, for example `docker compose --env-file .env -f docker-compose.yml -f .release/current.compose.json up -d --no-build --wait daemon web` from the deployment directory while no release operation is running. A plain `update` also selects the newest product release and is not a URL-only operation.

## License

Licensed under the [Apache License 2.0](LICENSE).

## Adopt versioned product releases on an existing customer host

Back up PostgreSQL and `/opt/opsrabbit` configuration, including encryption keys, authentication selection and sandbox policies. Download a concrete **new installer release** containing `migrate.sh`, verify its published archive checksum, extract it and review the migration. Existing v1.3.4 downloads do not contain this migration.

From the extracted bundle:

```bash
sudo ./migrate.sh --backup-confirmed
# Or select an exact product release:
sudo ./migrate.sh --backup-confirmed --version v1.1.1
```

For a nonstandard directory, pass the existing `OPSRABBIT_DEPLOY_DIR` through sudo explicitly. Migration backs up the old helper and `.env` once in `.release-migration-backup` (restricted to the deployment owner), installs the new helper and authentication/release libraries, and adopts a complete product release. It does not replace your Compose/TOML files, public URL, secrets or volumes. Keep the backup until the migration is verified, then remove that specific backup directory as an administrator according to your configuration-backup policy.

OpenSandbox must already use the documented 1.1.1 server/execd/egress pins and the required host AppArmor policy. The migration preserves provider configuration; verify compatibility before running it, and complete the provider/browser upgrade sections first. Legacy hosts without `.aws-auth` must explicitly choose their deployment identity. A successful AWS identity check alone does not prove image access; candidate manifest and layer pulls are required before maintenance.

Application startup performs its normal database migrations. Historical OpsRabbit sandbox aliases become the sandbox pin baked into the selected backend release; custom sandbox image values and enablement remain unchanged. Existing sandbox containers must retire before using a changed image. Do not automatically downgrade binaries after a database migration; use the release-compatible backup/recovery procedure.

## Product release selection and recovery

The first product version is `v1.1.1`; the application build workflow reserves a new patch version per run by default. Release operators can choose minor or major. Backend/frontend share the version and source revision. Installer versions are separate. Product release manifests live under `opsrabbit-vX.Y.Z` in this repository; automatic selection ignores installer `vX.Y.Z` tags, drafts and prereleases and compares SemVer numerically. Catalog failures leave the running deployment unchanged. Version reservations from failed builds are never published to customers.

```bash
opsrabbitctl status
opsrabbitctl update --backup-confirmed
opsrabbitctl update --version v1.1.2 --backup-confirmed
```

The helper stores current/previous/pending manifests under `.release` with private directory permissions and locks release operations. On interruption, `status` reports the pending release and start/restart refuses to bypass recovery. Resume with the **same** version and backup confirmation after investigating the failure. No automatic rollback is attempted; older versions are rejected because database compatibility cannot be inferred from an image tag.

Updates require maintenance downtime. Put any external frontend proxy/cache into maintenance as well; stopping the Compose web service cannot invalidate a browser tab or an externally hosted frontend. All customer-facing serving must be restored only after the matched backend/frontend pair is verified. Restart/start does not discover a newer version. Image updates do not update helper code, Compose/TOML files or host policies; upgrade those separately when a release requires it.
