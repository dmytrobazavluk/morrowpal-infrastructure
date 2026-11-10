# Update Production Infrastructure

Run commands from `infrastructure`.

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved. Select the
deployment target with the matching Ansible inventory and environment variable
file. Apply and validate changes in staging first.

Use this procedure for infrastructure-only changes that do not publish a new
backend, app, or website image. Examples include changes to:

- `shared/docker-compose.yml`
- `shared/runtime/envoy/envoy.yaml.j2`
- `shared/runtime/envoy/tls-certificate-sds.yaml.j2`
- the MorrowPal systemd unit or service scripts

Use the component-specific update procedures when deploying a new application
image. Use the installation, TLS, or host-replacement procedure when the change
belongs to one of those workflows.

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
checkout for public web runtime settings; set `morrowpal_frontend_directory` if
that checkout is elsewhere.

Confirm AWS identity and host connectivity:

```bash
aws sts get-caller-identity
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -m ping
```

The AWS account must be `384078510608`.

## 2. Preview the Deployment

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  --check \
  --diff
```

Review the preview and confirm that it contains only the intended files and
container reconciliation. Existing immutable application image tags are read
from the production host, so an infrastructure-only deployment does not need
an image-tag variable.

The reconciliation behavior depends on the changed file:

- An Envoy configuration change recreates the single Envoy container.
- A Compose change reconciles non-API containers and rolls the two API slots
  one at a time using their currently recorded immutable tags.
- Service-script and systemd-unit changes are installed before reconciliation.
- Unchanged application images are not rebuilt or published.

Because production has one Envoy container, recreating it can cause a brief
public edge interruption.

## 3. Deploy

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml
```

Do not run `docker compose down` during routine deployment. The playbook copies
the infrastructure files, performs the required targeted reconciliation, and
checks the readiness endpoints.

## 4. Verify

```bash
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'

curl --fail --show-error --silent https://api.morrowpal.com/ready
curl --fail --show-error --silent https://app.morrowpal.com/ready
curl --fail --show-error --silent https://morrowpal.com/ready
```

For an Envoy change, also inspect its recent logs:

```bash
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -b -m command \
  -a 'docker logs --tail=200 morrowpal-envoy-1'
```

Exercise the routes affected by the change before declaring the deployment
complete. For a rate-limit change, run the guarded verification script:

```bash
shared/scripts/verify-rate-limit.sh \
  prod \
  https://api.morrowpal.com/ready \
  --confirm-production
```

Run the same check against staging without the production confirmation:

```bash
shared/scripts/verify-rate-limit.sh \
  staging \
  https://api.staging.morrowpal.com/ready
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
shared/scripts/verify-account-creation-rate-limit.sh \
  prod \
  https://api.morrowpal.com/accounts \
  --confirm-production
```

For staging:

```bash
shared/scripts/verify-account-creation-rate-limit.sh \
  staging \
  https://api.staging.morrowpal.com/accounts
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

ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  --check \
  --diff

ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml
```

Verify service status and all three public readiness endpoints after rollback.
