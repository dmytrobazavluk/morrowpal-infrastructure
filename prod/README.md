# Production Operations

This file is the canonical index for MorrowPal production installation,
deployment, and administration procedures.

Run commands from `infrastructure/prod` unless a document explicitly says
otherwise.

## Documentation Index

- [Install production from scratch](./docs/install-from-scratch.md)
- [Update production infrastructure](./docs/update-infrastructure.md)
- [Update the backend](./docs/update-backend.md)
- [Postmark operations](./docs/postmark.md)
- [Update the app](./docs/update-app.md)
- [Update the website](./docs/update-website.md)
- [Production TLS](./docs/tls.md)
- [Replace the production host](./docs/replace-host.md)
- [Production database administration](./docs/admin.md)
- [Recently registered users query](./docs/queries/recent-users-correspondences.md)

## Environment

- AWS account: `384078510608`
- AWS Region: `us-east-2`
- Production Availability Zone: `us-east-2c`
- Production host: `3.12.65.199`
- SSH user: `ec2-user`
- Ansible inventory group: `production`
- Ansible host alias: `01`
- Deployment root on EC2: `/opt/morrowpal`
- MySQL data mount: `/var/lib/morrowpal`

The private SSH key is stored outside the infrastructure repository at
`../../morrowpal-prod-01.pem`. Keep it readable only by its owner:

```bash
chmod 400 ../../morrowpal-prod-01.pem
```

## Public Hostnames

- `api.morrowpal.com` routes to the backend API.
- `app.morrowpal.com` routes to the Flutter web app.
- `morrowpal.com` routes to the public landing page.
- `www.morrowpal.com` permanently redirects to `morrowpal.com`.
- `admin.morrowpal.com` and `back.morrowpal.com` are reserved and currently
  return HTTP 404.
- Unknown hostnames return HTTP 421.

All names on the production certificate resolve to the stable production IPv4
address. They must not have AAAA records until the production edge supports
IPv6. See [Production TLS](./docs/tls.md).

## Runtime Architecture

Envoy is the only public container. It terminates TLS and routes requests to:

- `backend-api-blue` and `backend-api-green`, with active readiness checks and
  blue-green traffic control.
- `app`, a non-root Nginx container serving the Flutter web build.
- `website`, a separate non-root Nginx container serving the landing page.

The remaining private services are:

- `mysql`
- `backend-job-dispatch`
- `backend-job-cleanup`

MySQL data lives on a separately retained, encrypted EBS volume. Runtime
passwords, the JWT signing secret, and the Postmark server token live in AWS
Secrets Manager and are resolved only at service startup.

## Container Repositories

- `morrowpal/prod/backend-api`
- `morrowpal/prod/backend-job`
- `morrowpal/prod/app`
- `morrowpal/prod/website`

Images use immutable `build-N-REVISION` tags. The backend API and job images use
the same backend Git revision. The app uses its own Git revision. Until the
website has its own Git repository, its revision is a digest of the deployable
website files. Backend, app, and website releases have independent build
sequences and are deployed independently.

Do not use mutable tags such as `latest` in production.

## Operational Rules

1. Confirm the AWS identity before any AWS mutation:

   ```bash
   aws sts get-caller-identity
   ```

2. Validate CloudFormation locally and with AWS before creating a change set.
3. Review every production change set before execution.
4. Never retrieve secret values with AWS CLI, SDK, or agent tools.
5. Use Secrets Manager dynamic references with `asm-exec` for automated secret
   resolution. Human-only GUI access is documented separately in
   [database administration](./docs/admin.md).
6. Publish and scan an immutable image before deploying its tag.
7. Prefer the Ansible deployment playbook over direct host commands because it
   also reconciles infrastructure files and verifies readiness.

## Deployment Behavior

The systemd service owns full-stack startup after host boot and full-stack
shutdown. Routine deployments do not restart it on an existing host.

Ansible applies service-specific deployment behavior:

- New services are created without stopping existing services.
- Non-API services with changed Compose definitions are reconciled in place.
- MySQL remains running unless its own Compose definition changes.
- API image and Compose configuration changes use the rolling blue-green
  release command, which recreates only one API slot at a time.
- App image releases replace only the app container.
- Website image releases replace only the website container.
- Envoy configuration changes recreate only Envoy. Because production has one
  Envoy container, that operation can cause a brief public edge interruption.

A full-stack restart is reserved for initial startup, host reboot, explicit
operator action, or recovery.

## Connectivity and Status

Verify Ansible access:

```bash
ansible production -m ping
```

Connect directly when necessary:

```bash
ssh -i ../../morrowpal-prod-01.pem ec2-user@3.12.65.199
```

Inspect the production service without exposing secrets:

```bash
ansible 01 -b -m command -a 'systemctl status morrowpal --no-pager'
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
```

### Direct Docker Compose Access

The production Compose project and its image-tag files are stored under
`/opt/morrowpal` on the EC2 host:

```text
/opt/morrowpal/
├── docker-compose.yml
├── api-blue-image-tag
├── api-green-image-tag
├── job-image-tag
├── app-image-tag
├── website-image-tag
└── envoy/
    ├── envoy.yaml
    └── tls-certificate-sds.yaml
```

For routine status checks, prefer the service helper:

```bash
sudo /usr/local/sbin/morrowpal-service status
```

To run read-only Docker Compose commands directly, enter a root shell and load
the immutable image tags required by the Compose file:

```bash
sudo -i
cd /opt/morrowpal

export API_BLUE_IMAGE_TAG="$(<api-blue-image-tag)"
export API_GREEN_IMAGE_TAG="$(<api-green-image-tag)"
export JOB_IMAGE_TAG="$(<job-image-tag)"
export APP_IMAGE_TAG="$(<app-image-tag)"
export WEBSITE_IMAGE_TAG="$(<website-image-tag)"

docker compose ps
docker compose logs --tail=200 app
docker compose logs --tail=200 website
docker compose logs --tail=200 envoy
```

Do not inspect files under `/run/morrowpal/secrets`. Do not use
`docker compose down` during normal operation because it removes the complete
stack and causes downtime. Use the Ansible deployment playbook or the approved
service and release helpers for state-changing operations.

Verify public readiness:

```bash
curl --fail --show-error --silent https://api.morrowpal.com/ready
curl --fail --show-error --silent https://app.morrowpal.com/ready
curl --fail --show-error --silent https://morrowpal.com/ready
```

## CloudFormation Failure Diagnosis

If a stack operation fails, inspect every failed event and distinguish the
specific root failures from resources cancelled by rollback:

```bash
aws cloudformation describe-events \
  --stack-name STACK_NAME \
  --filters FailedEvents=true \
  --region us-east-2
```

Do not retrieve stack failures with `describe-stack-events`; it does not expose
the filtered validation event workflow used by these runbooks.
