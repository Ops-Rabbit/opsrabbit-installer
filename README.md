# OpsRabbit AWS Image-Only Installer

This bundle deploys the core OpsRabbit stack and its OpenSandbox lifecycle service without copying application source code to the server. It contains only the installer, operations helper, runtime configuration, and image-only Compose manifest.

## Quick install

Install the tagged `v1.5.0` release on a Debian or Ubuntu host:

```bash
curl -fsSL https://github.com/Ops-Rabbit/opsrabbit-installer/releases/download/v1.5.0/install.sh | sudo bash
```

This URL points to an immutable GitHub Release asset, not the mutable `main` branch. The release bootstrap is pinned internally to the same `v1.5.0` tag. It downloads that release's archive and published SHA-256 file, verifies the archive, and only then starts the interactive installer. Review `install.sh` before piping it to a privileged shell if your security policy requires it.

To install another version, replace `v1.5.0` in the URL with the required release tag. Run it from an interactive SSH session; the installer now fails immediately with guidance if no controlling terminal is available.

## Requirements

- Ubuntu Server 24.04 LTS or 26.04 LTS, or Debian 13
- x86-64 CPU architecture
- `root` or passwordless `sudo` for the initial installation
- Network access to the configured Amazon ECR registry and public container registries
- ECR pull permissions for `vg-backend`, `vg-webapp`, `vg-sandbox`, and `vg-opensandbox-server`
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

In a tighter IAM policy, keep `ecr:GetAuthorizationToken` on `*` and scope the other actions to the four repository ARNs. Cross-account pulls also require the corresponding ECR repository policies to allow that account or principal.

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

Backend and frontend images are selected together by the product release; independent image environment overrides are rejected.

Advanced deployments can override defaults with `OPSRABBIT_INSTALL_USER`, `OPSRABBIT_INSTALL_DIR`, `OPSRABBIT_AWS_REGION`, `OPSRABBIT_ECR_REGISTRY`, `OPSRABBIT_SANDBOX_IMAGE`, `OPENSANDBOX_PORT`, or `OPSRABBIT_WEB_PORT`.

It configures Docker's official stable apt repository and installs or upgrades Docker Engine, Buildx, and Compose to that repository's latest candidate. When migrating from distribution-provided Docker packages, their removal can briefly interrupt running containers, but Docker data in `/var/lib/docker` is preserved. It also installs the official AWS CLI v2 bundle when `aws` is unavailable, creates the deployment user, generates persistent application and OpenSandbox secrets, logs in to ECR, pre-pulls the sandbox image, starts the services, and checks backend, web, and OpenSandbox health. On Ubuntu hosts enforcing restricted unprivileged user namespaces, it installs the browser-specific AppArmor policy and uses Ubuntu's packaged Bubblewrap policy for ordinary commands when available, otherwise installing the bundled fallback. Policy changes are rolled back if installation fails. It does not disable the host-wide restriction or require a reboot. This also removes an unchanged conflicting fallback left by installer `v1.3.0` on Ubuntu 26.04.

Product releases use immutable version tags. Floating image aliases are not used. Installer **v1.5.0** includes versioned product-release management and post-install HTTPS commands. Older published release assets remain unchanged. Installer versions and application/product versions are separate.

## AWS authentication

Choose one of the following during installation:

1. **Sign in with AWS CLI:** open the displayed URL in your browser and enter the authorization code in the server terminal. This uses `aws login --remote` with the managed `opsrabbit-deploy` profile. An existing older AWS CLI must support `aws login`; otherwise update AWS CLI v2 or select temporary credentials.
2. **Enter temporary AWS credentials:** supply your access key, secret key and session token through hidden prompts. The session token is required for temporary credentials. Long-lived access keys can omit the token.
3. **Use this machine's EC2 role:** explicitly opt in only when that role is intended to pull the deployment images. On a client machine, choose your own login or credentials instead.
4. **Use an existing AWS CLI profile:** enter a profile already configured for the deployment user. Profiles belonging to `ubuntu`, `ssm-user` or `root` are not copied. Existing IAM Identity Center profiles can renew through device authorization.

The helper displays the selected AWS account and role/user, logs in to ECR, and checks access to the configured backend, web, sandbox workload, and effective Compose lifecycle-server image during authentication setup/login. Initial product-image placeholders are checked after release selection. Deploy/update pulls all candidate images and Compose dependencies before running services are changed. A successful ECR login alone does not prove image access. Failed selection returns to the installer menu; normal deployment/update commands fail with renewal instructions. The helper clears inherited AWS credentials and provider/endpoint overrides. EC2 metadata is disabled unless the instance-role option was explicitly selected.

The method/profile selection is stored in `/opt/opsrabbit/.aws-auth` with mode `0600`. Temporary credentials are stored separately in the deployment user's `~/.aws/opsrabbit/credentials` with directory mode `0700` and file mode `0600`; they are never written to the application's `.env`. Browser login uses `~/.aws/opsrabbit/config` and AWS CLI's login cache. Existing profiles use that user's standard AWS CLI files. Successful switches away from temporary credentials remove the managed credentials file. AWS CLI owns browser/SSO session expiry and cache management.

For renewal, a new selection, or identity inspection, run from your normal sudo-capable account:

```bash
opsrabbitctl auth login
opsrabbitctl auth configure
opsrabbitctl auth status
```

`auth login` renews the selected browser, temporary-credential or SSO method and checks image access again. Other existing profile types must be renewed through their configured AWS credential provider. Legacy installations without an explicit selection must run `opsrabbitctl auth configure` after upgrading the helper. No manual exports or Linux-user switching are required.

## Operations

For a caller that already has an ECR password, `deploy` and `update` accept the optional `--ecr-password-stdin` flag:

```bash
aws ecr get-login-password --region us-east-1 \
  | opsrabbitctl update --backup-confirmed --ecr-password-stdin
```

The supplied password is used only for that invocation, through a private temporary Docker configuration that is removed on exit. Do not pass it in command arguments. The helper requires non-empty piped or redirected input and does not echo rejected passwords. This mode needs neither AWS CLI nor a saved AWS authentication selection on the deployment host; issuing the password remains the caller's responsibility. Existing AWS authentication settings are preserved. Without the flag, the selected AWS authentication and renewal behavior is unchanged. Release selection, backup confirmation, image checks and recovery safeguards are the same in both modes.

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

`opsrabbitctl update --backup-confirmed` selects the highest complete stable product release, validates its paired version manifest and selected AWS access, pulls all candidate images, stops web before the backend, waits for OpenSandbox health and verifies its running image, waits for the new daemon and workers, then starts and verifies the matched web image. OpenSandbox remains available during backend shutdown for managed-sandbox cleanup. A failed update after maintenance starts keeps web stopped and records the pending version for explicit recovery. `stop` and `restart` use the same cleanup ordering. `opsrabbitctl health` also verifies OpenSandbox authentication, checks that the running lifecycle container matches its effective Compose image, and confirms that the configured workload image is present.

To proceed without confirming a backup, use `opsrabbitctl update --skip-backup` (also supported by `deploy`). Choose either `--backup-confirmed` or `--skip-backup`; without either, commands keep requiring backup confirmation. Neither flag creates a backup. The one-time `migrate.sh` entrypoint still requires `--backup-confirmed`.

Configuration is stored at `/opt/opsrabbit/.env` by default. Back it up securely. Never regenerate `OPSRABBIT_NODE_ENCRYPTION_KEY`; doing so makes previously stored encrypted credentials unreadable.

Persistent data is held in Docker named volumes. Back up PostgreSQL, the OpsRabbit data volume, and the `opensandbox-state` lifecycle database before upgrades.

## Enable sandbox execution

The installer starts OpenSandbox and initializes its application connection settings only when no sandbox configuration has been saved. New installations select the OpenSandbox provider, save the endpoint and encrypted API key, and use the installed sandbox image with workspace-only policy and session scope. **Execution remains disabled with mode Off** until an administrator enables it in **Configuration → Sandbox** and selects an execution mode.

The endpoint and API key remain editable in the UI. Reinstallation preserves any existing application configuration, including custom endpoints, keys and enabled state; routine upgrades do not initialize these settings. Initialization requires a backend release containing the initialization command. For an already running, unconfigured installation, run `sudo opsrabbitctl sandbox initialize`. This also preserves any saved configuration. After a UI reset, an explicit initialization can populate the reset settings again.

For manual configuration, use:

- endpoint: `http://opensandbox-server:8080`
- image: the `OPSRABBIT_SANDBOX_IMAGE` value from `/opt/opsrabbit/.env`
- API key: the `OPENSANDBOX_SERVER_API_KEY` value from `/opt/opsrabbit/.env`

Use session or agent scope, keep worker splitting disabled, and use the workspace-only filesystem policy with deny-all networking for the strict default. Run one controlled command after enabling the provider and confirm that it succeeds.

Since `v1.3.3`, the bundle uses sandbox host-port pool `20000-29999` (10,000 ports). The `v1.3.2` installer uses `40000-41000`; installations from that release need the migration below before using the new range. Check existing host listeners, Docker port bindings, and `sysctl net.ipv4.ip_local_port_range` before using it. The pool avoids Linux's usual `32768-60999` ephemeral range, but a range change alone does not fix upstream sandbox port-allocation races. The patched lifecycle image described below addresses that allocation race; capacity exhaustion or unrelated host listeners can still prevent allocation.

For an existing installation using `40000-41000`, update only `port_range_min` and `port_range_max` in `/opt/opsrabbit/opensandbox-config.toml`, preserving other settings. Apply your existing trusted-network restrictions to the new range, then run `cd /opt/opsrabbit && docker compose up -d --no-deps --force-recreate --wait opensandbox-server`. Keep the old range protected until existing sandboxes retire; their ports remain unchanged. Preserve `opensandbox-state` and allow a brief lifecycle/proxy interruption during recreation. No image rebuild is required.

## OpenSandbox 1.1.1 upgrade

The `v1.3.3` bundle pins the server, execd, and egress images to the digests in the [official OpenSandbox 1.1.1 release manifest](https://github.com/opensandbox-group/OpenSandbox/blob/release-1.1.1/docs/releases/1.1.1.yaml). This includes the upstream private-procfs compatibility fix needed by the workspace-only browser. These are digest pins, not a claim of verified image signatures or attestations. Published installer `v1.3.2` remains unchanged and contains the older provider images.

Pair this bundle with a backend image containing the SDK 1.1.1 byte-range file-download fix. Do not upgrade the provider independently of that backend fix.

For an existing deployment:

1. Back up the persistent data and configuration described above, disable sandbox execution, and let existing managed sandboxes retire.
2. Replace only `opensandbox-server.image` in the deployed `docker-compose.yml` with the pin in [the source Compose file](bundle/docker-compose.yml). Replace only `runtime.execd_image` and `egress.image` in the deployed `opensandbox-config.toml` with the pins in [the source runtime configuration](bundle/opensandbox-config.toml). Preserve all other settings, `.env`, volumes, port restrictions, and AppArmor configuration. Do not rerun the installer to replace customized configuration.
3. For legacy helper versions, set `OPSRABBIT_DAEMON_IMAGE` in `.env` to the backend image containing the matching fix, then run `opsrabbitctl update`. It does not download new Compose or TOML files; step 2 is required. With the new helper, select a complete product release containing the fix with `opsrabbitctl update --version vX.Y.Z --backup-confirmed`. The helper preserves daemon-first shutdown and reconnects the lifecycle server to Docker's runtime bridge.
4. Validate health, then enable sandboxing for a controlled thread and check workspace commands, binary/empty file reads, permitted network access, and browser open → snapshot → close before restoring normal sandbox traffic.

The provider upgrade itself does not require rebuilding the OpsRabbit sandbox workload image. Existing sandbox containers retain their old execd/egress runtime until replaced. Ubuntu AppArmor/user-namespace setup is unchanged; this update does not disable host restrictions or require a reboot.

## Patched OpenSandbox lifecycle-server upgrade

```text
vg-opensandbox-server:1.1.1-opsrabbit.1@sha256:b6e24fe81bb3a5ee1bfbe3169990b129e748f775d878f5272b58cef27a0cf704
```

Docker allocates data-plane host ports atomically within the configured pool, rather than the server checking a free port and binding it later. Endpoint discovery follows the actual Docker binding, including egress-sidecar network ownership. This is an OpsRabbit downstream overlay, not an upstream OpenSandbox release or a claim of verified signatures/attestations. `OPSRABBIT_SANDBOX_IMAGE` remains the separate `vg-sandbox` workload image. No workload rebuild is required for this provider-only change; execd/egress pins, API key, AppArmor and port range remain unchanged.

For an existing host already on the documented OpenSandbox 1.1.1/browser configuration:

1. Grant the selected deployment identity pull access to `vg-opensandbox-server`, including its cross-account repository policy where applicable. Back up the database, lifecycle state, `.env`, Compose and TOML securely. Disable application sandbox execution and allow managed sandboxes to retire before recreating the lifecycle service.
2. Edit **only** `services.opensandbox-server.image` in the deployed `docker-compose.yml` to the pin in [the source Compose file](bundle/docker-compose.yml), preserving the existing registry, configuration, secrets, volumes and network restrictions. If your registry is a mirror, publish the identical image there first. A custom lifecycle image is preserved and verified against that effective Compose selection, not silently replaced by the helper.
3. From the new extracted bundle, refresh the helper and adopt/reapply a compatible complete product release using the [existing-host migration](#upgrade-an-existing-installation-to-installer-v150) procedure (`sudo ./migrate.sh --backup-confirmed --version vX.Y.Z`). This is also a product deployment, not a helper-only refresh. It does **not** copy new Compose/TOML files: step 2 is required. Do not rerun the full installer or delete lifecycle state. All pulls finish before maintenance; the helper then waits for lifecycle health, reconnects the runtime bridge and verifies the running image before starting the application.
4. Run `opsrabbitctl status` and `opsrabbitctl health`. Confirm no pending release, then enable sandboxing for one controlled thread and verify workspace commands, file reads, permitted network access and browser open → snapshot → close before restoring normal traffic. Existing sandbox settings are never enabled automatically.

Lifecycle recreation briefly interrupts its API/proxy. No host reboot is required. If startup or image verification fails after maintenance starts, web stays stopped and the pending product version must be recovered as described below. Earlier failures during image pulls leave the existing services unchanged.

## Browser/AppArmor compatibility upgrade

The `v1.3.3` bundle also carries the browser-specific AppArmor policy. Published installer `v1.3.2` does not include it. Unlike the provider-only 1.1.1 upgrade above, this browser fix requires a **rebuilt sandbox workload image and matching backend** containing the browser compatibility fix. Keep the existing image tags if desired, but verify their new digests contain that fix before upgrading.

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
- The default Compose setup serves HTTP. Enable optional TLS in the existing Nginx with `opsrabbitctl https configure`, or terminate TLS at a load balancer and set the public origin to its HTTPS URL.
- Keep SSH key-only, restrict administration sources, and do not expose ports 54329 or 8384 publicly.

## Re-running the installer

The installer preserves an existing `.env` so that application secrets are not rotated accidentally. Use an explicit product version with `opsrabbitctl update --version vX.Y.Z --backup-confirmed` to choose application images; the manifest owns managed image references. Do not edit those references independently.

For a URL-only change, preserve the image pins and edit the relevant URL setting, then recreate the affected service using the installed override, for example `docker compose --env-file .env -f docker-compose.yml -f .release/current.compose.json up -d --no-build --wait daemon web` from the deployment directory while no release operation is running. A plain `update` also selects the newest product release and is not a URL-only operation.

## License

Licensed under the [Apache License 2.0](LICENSE).

## Upgrade an existing installation to installer v1.5.0

Use this migration for older installations, including hosts installed with v1.3.4 or v1.4.x. **Do not use the fresh-install curl command as the upgrade procedure.** Updating application images alone does not update `opsrabbitctl` or its bundled libraries.

1. Schedule maintenance downtime. Back up PostgreSQL, the OpsRabbit data volume, `opensandbox-state`, and the deployment configuration (normally `/opt/opsrabbit`), including `.env`, encryption keys, authentication selection, certificates and sandbox policies. Verify that you can restore the backup. `--backup-confirmed` records your confirmation; it does not create a backup. Check the OpenSandbox prerequisites below before proceeding.
2. On the existing host, download and verify the pinned installer bundle in a new temporary directory:

   ```bash
   upgrade_dir="$(mktemp -d)"
   cd "$upgrade_dir"
   release_url="https://github.com/Ops-Rabbit/opsrabbit-installer/releases/download/v1.5.0"
   curl -fSL "$release_url/opsrabbit-aws-image-bundle.tar.gz" -o opsrabbit-aws-image-bundle.tar.gz
   curl -fSL "$release_url/opsrabbit-aws-image-bundle.tar.gz.sha256" -o opsrabbit-aws-image-bundle.tar.gz.sha256
   sha256sum --check opsrabbit-aws-image-bundle.tar.gz.sha256 && \
     tar -xzf opsrabbit-aws-image-bundle.tar.gz
   ```

   Expect `opsrabbit-aws-image-bundle.tar.gz: OK`. Stop if either download or checksum verification fails; do not run the migration.
3. Review `opsrabbit-aws-image-bundle/migrate.sh`, then run **one** of these commands from the extracted bundle:

   ```bash
   cd opsrabbit-aws-image-bundle
   # Adopt the latest complete stable application/product release:
   sudo ./migrate.sh --backup-confirmed
   # Alternatively, select a specific compatible product version:
   # sudo ./migrate.sh --backup-confirmed --version vX.Y.Z
   ```

   Replace `vX.Y.Z` with an actual product version from the release catalog, not installer version `v1.5.0`. For a nonstandard deployment directory, use `sudo env OPSRABBIT_DEPLOY_DIR=/your/existing/path ./migrate.sh --backup-confirmed` instead. The host needs `jq` and `flock` (`util-linux`); install missing prerequisites before migration.
4. Check the result:

   ```bash
   opsrabbitctl status
   opsrabbitctl health
   ```

   Expect the selected product release to be current, no pending release, and healthy backend, web and OpenSandbox services. Use the same explicit deployment-directory environment setting for a nonstandard path. If migration fails, inspect `status` and follow [Product release selection and recovery](#product-release-selection-and-recovery); do not rerun the fresh installer or downgrade application binaries.

Migration installs the new helper and authentication/release libraries and adopts a complete product release; **it is not a helper-only update**. Hosts with an earlier versioned-release helper also need this refresh. It preserves customer Compose/TOML files, public URL, secrets and volumes. It does not automatically enable HTTPS: after a successful migration, follow [Post-install HTTPS with the existing Nginx](#post-install-https-with-the-existing-nginx). HTTP remains the default.

OpenSandbox must already use the documented 1.1.1 server/execd/egress pins and the required host AppArmor policy. The migration preserves provider configuration; verify compatibility before running it, and complete the provider/browser upgrade sections first. Legacy hosts without `.aws-auth` must explicitly choose their deployment identity. A successful AWS identity check alone does not prove image access; candidate image pulls are required before maintenance.

Application startup performs its normal database migrations. Historical OpsRabbit sandbox aliases and official `YYYYMMDD-RUN` or `YYYYMMDD-RUN-ATTEMPT` build tags become the sandbox pin baked into the selected backend release; custom sandbox image values and enablement remain unchanged. Existing sandbox containers must retire before using a changed image. Do not automatically downgrade binaries after a database migration; use the release-compatible backup/recovery procedure.

## Product release selection and recovery

The first product version is `v1.1.1`; the application build workflow reserves a new patch version per run by default. Release operators can choose minor or major. Backend/frontend share the version and source revision. Installer versions are separate. Product release metadata is served directly over S3 HTTPS: [`catalog.json`](https://opsrabbit-releases-921870554228-us-east-1.s3.us-east-1.amazonaws.com/releases/catalog.json) lists complete stable versions, and each manifest lives at `https://opsrabbit-releases-921870554228-us-east-1.s3.us-east-1.amazonaws.com/releases/vX.Y.Z/release.json`. Automatic selection compares SemVer numerically; exact selection must also be listed in the catalog. The publisher uploads the versioned manifest before adding its version to the catalog. An empty catalog means no product release is available. Metadata downloads need no AWS credentials; image pulls still use the selected ECR authentication. Installer archive releases remain separate. Catalog failures leave the running deployment unchanged. Version reservations from failed builds are never published to customers.

```bash
opsrabbitctl status
opsrabbitctl update --backup-confirmed
opsrabbitctl update --version v1.1.2 --backup-confirmed
```

The helper stores current/pending manifests under `.release` with private directory permissions and locks release operations. On interruption, `status` reports the pending release and start/restart refuses to bypass recovery. Resume with the **same** version and backup confirmation after investigating the failure. No automatic rollback is attempted; older versions are rejected because database compatibility cannot be inferred from an image tag.

Updates require maintenance downtime. Put any external frontend proxy/cache into maintenance as well; stopping the Compose web service cannot invalidate a browser tab or an externally hosted frontend. All customer-facing serving must be restored only after the matched backend/frontend pair is verified. Restart/start does not discover a newer version. Image updates do not update helper code, Compose/TOML files or host policies; upgrade those separately when a release requires it.

## Post-install HTTPS with the existing Nginx

A fresh Compose installation serves HTTP only. HTTPS is optional and uses the existing web container's Nginx; no ACM, DNS provider, certificate issuer or additional proxy service is required. These commands apply to Compose deployments, not the separate ECS template. Use a web image that includes the OpsRabbit `WEB_TLS_MODE` entrypoint and HTTPS templates.

Obtain a certificate separately and configure DNS for a hostname you control. For a private EC2 instance, use a certificate issuer's DNS-validation method if the server cannot receive public validation requests. Certificate issuance and DNS changes are not performed by this CLI. EventBridge requires a publicly trusted certificate; a self-signed certificate is suitable only for isolated tests or clients configured to trust it.

Run as the deployment user, with Docker access and permission to read the supplied files:

```bash
opsrabbitctl https configure \
  --hostname opsrabbit.example.com \
  --cert /secure/path/fullchain.pem \
  --key /secure/path/privkey.pem \
  --http-mode keep
```

The PEM certificate file must contain the leaf certificate first, followed by its intermediate chain. Supply the matching, unencrypted PEM private key. The command checks certificate readability, expiry, hostname and key matching. It does not establish public trust or verify the complete chain; check the final endpoint with a normal TLS client. OpenSSL from the supported Debian/Ubuntu host and Docker Compose **2.24.4 or newer** are required; vendor suffixes such as `-desktop.1` are accepted. Deployment directory paths for this command must contain only letters, digits, underscores, dots, slashes and hyphens; bind addresses currently support IPv4.

| HTTP mode | Published ports | Behavior |
| --- | --- | --- |
| `keep` (default) | Existing HTTP port and HTTPS 443 | Serve HTTP and HTTPS independently |
| `redirect` | Existing HTTP port and HTTPS 443 | Redirect HTTP requests to HTTPS |
| `disable` | HTTPS 443 only | Remove the web container's published HTTP port |

Use `--https-port 8443` for a different host HTTPS port in `keep` or `disable` mode. Redirect mode requires port 443 because the existing Nginx redirect template uses standard HTTPS URLs. Nginx uses port 443 inside the container in all HTTPS modes. Check that the chosen host ports are free and adjust the firewall/security group deliberately; this command does not change network access. Keeping HTTP allows unencrypted requests, including webhook credentials sent over HTTP, so use the HTTPS URL for authenticated traffic.

Configuration validates the merged Compose manifest, copies certificates beneath protected deployment directories, creates `docker-compose.https.yml`, and sets `OPSRABBIT_WEB_ORIGIN` and `OPSRABBIT_NODE_BASE_URL` to the HTTPS origin and its `/api` URL. It recreates the web and daemon services as needed, waits up to 120 seconds for health, and restores the previous configuration with a service-recovery attempt if activation fails or receives an interrupt. Expect a brief service interruption. Both protocols being reachable does not configure separate application login origins: HTTPS becomes the canonical application origin.

The backend remains HTTP on the Docker network. The certificate and key are mounted read-only into the existing Nginx container. Their host parent directories are mode `0700`; mounted files are readable by the non-root container process. No certificate or key content is printed by the helper. Restrict deployment-user and Docker access.

Rotate certificates after renewal with:

```bash
opsrabbitctl https reload \
  --cert /secure/path/renewed-fullchain.pem \
  --key /secure/path/renewed-privkey.pem
opsrabbitctl health
```

`reload` requires both files, revalidates them, preserves the saved hostname/HTTP mode/HTTPS port, and recreates the web container to switch read-only certificate mounts. It is not an in-place Nginx signal. The new configuration is committed before removing the previous managed certificate copy. A cleanup failure reports the unused directory and keeps the new HTTPS configuration active. If activation and service recovery both fail, the command retains and reports the protected recovery snapshot and candidate certificates; inspect the running services and restore the required files from that snapshot before retrying. Source files are never deleted or edited. Certificate issuance, renewal scheduling and invoking this command after renewal remain your responsibility. Re-run `https configure` to change hostname, mode or port.

All regular helper lifecycle commands automatically include the saved HTTPS override. The health command checks the backend over loopback HTTP and the web endpoint over HTTPS with hostname/chain verification. For a private CA used by internal clients, configure the client's trust store. The container's local readiness probe bypasses certificate trust verification only to check that its HTTPS listener is running.

For an existing installation, upgrade the installed helper and its bundled authentication/release libraries using the installer migration procedure before using these commands. Do not replace only the helper on a legacy installation. An existing base Compose file can remain unchanged; `!override` replaces its port list. Running Docker Compose manually without `-f docker-compose.https.yml` omits the saved TLS setup. Do not delete that override while HTTPS origin settings remain active. If a configure process is forcibly killed, inspect deployment state before removing a stale `.https-lock` directory and re-running configuration.

For EventBridge to reach a private endpoint, configure its private API Destination and VPC Lattice connectivity separately. Enabling HTTPS does not make a private instance internet-accessible.

## AWS Spot notification setup

See [Send AWS Spot notifications to private OpsRabbit](docs/aws-spot-notifications.md) for same-account and cross-account setup with copyable AWS CLI examples.
