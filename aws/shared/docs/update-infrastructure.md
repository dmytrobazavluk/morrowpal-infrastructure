# Update infrastructure configuration

Run commands in Bash from `infrastructure/aws`. Select the environment explicitly
and keep the setup and following commands in the same shell:

```bash
ENVIRONMENT=staging
CONFIRMATION=()
case "$ENVIRONMENT" in
  staging) PUBLIC_DOMAIN=staging.morrowpal.com ;;
  prod) PUBLIC_DOMAIN=morrowpal.com; CONFIRMATION=(--confirm-production) ;;
  *) printf 'Select staging or prod.\n' >&2; exit 1 ;;
esac
```

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved. The
deployment command selects and validates the matching inventory and configuration.
Apply and validate changes in staging first.

Select `ENVIRONMENT=prod` only after that production gate is satisfied.

EC2 CloudFormation change sets use an explicit `AmiId`. The guarded
`morrowpal-infrastructure-change-set.sh` wrapper resolves the Region-local AMI
using the exact image name, owner, and architecture in `shared/ec2-image.json`
when creating a host stack. It preserves the validated
instance's current AMI when updating it. Review any proposed instance
replacement separately; an AMI upgrade belongs to the host-replacement
procedure rather than a routine configuration update.

Use this procedure for infrastructure-only changes that do not publish a new
backend, app, or website image. Examples include changes to:

- `shared/docker-compose.yml`
- `shared/runtime/envoy/envoy.yaml.j2`
- `shared/runtime/envoy/tls-certificate-sds.yaml.j2`
- the MorrowPal systemd unit or service scripts

For new application images, use the [backend](./update-backend.md),
[app](./update-app.md), or [website](./update-website.md) update guide.
Use the [installation guide](./install-from-scratch.md), [TLS guide](./tls.md),
or [host-replacement planning checklist](./replace-host.md) when the change
belongs to one of those workflows. Host replacement remains gated pending a
supported implementation and staging rehearsal.

CloudFormation resource changes use separate reviewed change sets through
`shared/scripts/morrowpal-infrastructure-change-set.sh`. A host configuration
deployment does not apply CloudFormation templates.

## 1. Preconditions

Review the infrastructure changes that will be deployed:

```bash
git status --short
git diff --check
git diff
```

Validate the resolved environment configurations locally:

```bash
bash shared/scripts/validate-local.sh
```

The validator renders the shared Compose configuration with explicit environment
values without deploying. Deployment uses immutable image tags recorded on the
selected host. The shared deploy playbook also requires the sibling frontend
checkout for public web runtime settings; use `--frontend-directory PATH` if
that checkout is elsewhere.

Confirm AWS identity and host connectivity:

```bash
aws sts get-caller-identity
ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
  -e "@environments/$ENVIRONMENT/vars.yml" -m ping
```

Use credentials for the account configured in the selected overlay. The wrapper
validates account, Region, stack outputs, instance identity, Elastic IP,
inventory, and overlay before host actions. Start stopped staging with
`shared/scripts/staging-lifecycle.sh start`. Finish staging deployments before
its nightly 1 AM America/Chicago shutdown.

## 2. Preview the Deployment

```bash
shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure "${CONFIRMATION[@]}" --check --diff
```

Review the preview and confirm that it contains only the intended files and
container reconciliation. Existing immutable application image tags are read
from the selected host, so an infrastructure-only deployment does not need
an image-tag variable.

The reconciliation behavior depends on the changed file:

- An Envoy configuration change recreates the single Envoy container.
- A Compose change reconciles non-API containers and rolls the two API slots
  one at a time using their currently recorded immutable tags.
- Service-script and systemd-unit changes are installed before reconciliation.
- Unchanged application images are not rebuilt or published.

Each environment has one Envoy container, so recreating it can cause a brief
public edge interruption.

## 3. Deploy

```bash
shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure "${CONFIRMATION[@]}"
```

Do not run `docker compose down` during routine deployment. The playbook copies
the infrastructure files, performs the required targeted reconciliation, and
checks the readiness endpoints.

## 4. Verify

```bash
ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
  -e "@environments/$ENVIRONMENT/vars.yml" -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'

curl --fail --show-error --silent "https://api.$PUBLIC_DOMAIN/ready"
curl --fail --show-error --silent "https://app.$PUBLIC_DOMAIN/ready"
curl --fail --show-error --silent "https://$PUBLIC_DOMAIN/ready"
curl --fail --show-error --silent "https://app.$PUBLIC_DOMAIN/version.json"
```

Verify that the app root serves the web client, its version matches the selected
release, and the website serves the expected landing page. Both web services
answer `/ready`, so content checks also establish that requests reached the
intended service. Envoy's Docker DNS clusters retire addresses removed from
service discovery even when another container reuses that address and answers
its health check.

For an Envoy change, also inspect its recent logs:

```bash
ansible morrowpal_hosts -i "environments/$ENVIRONMENT/inventory.ini" \
  -e "@environments/$ENVIRONMENT/vars.yml" -b -m command \
  -a 'docker logs --tail=200 morrowpal-envoy-1'
```

Exercise the routes affected by the change before declaring the deployment
complete. For a rate-limit change, run the guarded verification script:

```bash
shared/scripts/verify-rate-limit.sh "$ENVIRONMENT" \
  "https://api.$PUBLIC_DOMAIN/ready" "${CONFIRMATION[@]}"
```

The script sends 160 requests to the API readiness endpoint in controlled
batches of 20 per second. Envoy continuously refills the 120-token client-IP
bucket at 2 tokens per second, so the test exhausts that bucket while remaining
below the global bucket's 100-token-per-second refill rate. It passes only after
observing both HTTP 200 and HTTP 429 responses. The readiness endpoint normally
returns HTTP 200, so a 429 during this controlled burst demonstrates that the
edge limit is enforced without depending on an optional response header. The
test consumes the caller's client-IP bucket, so wait at least 60 seconds before
repeating it from the same public IP.

For a change to the anonymous account-creation limit, run its guarded
verification script instead:

```bash
shared/scripts/verify-account-creation-rate-limit.sh "$ENVIRONMENT" \
  "https://api.$PUBLIC_DOMAIN/accounts" "${CONFIRMATION[@]}"
```

This script sends 30 deliberately invalid `POST /accounts` requests. The first
requests reach backend validation and return HTTP 400 without creating
accounts; requests beyond the 25-token per-client-IP burst return an
Envoy-generated HTTP 429. The invalid payload is rejected by backend validation
with HTTP 400 before business logic runs, so the script can distinguish allowed
requests from Envoy-rejected requests without depending on an optional response
header. It verifies the selected environment's per-client-IP bucket only; the
isolated development test covers the global bucket across multiple simulated
client IPs.

## Rollback

Restore the previous infrastructure definitions in the local worktree, review
the reversal, and deploy it through the same playbook:

```bash
git diff --check
git diff

shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure "${CONFIRMATION[@]}" --check --diff

shared/scripts/deploy-images.sh "$ENVIRONMENT" infrastructure "${CONFIRMATION[@]}"
```

Verify service status and all three public readiness endpoints after rollback.
