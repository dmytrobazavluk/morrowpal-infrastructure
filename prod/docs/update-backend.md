# Update the Backend

Run commands from `infrastructure`.

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved.
The deployment command selects and validates the matching inventory and
configuration for the requested environment.

This procedure updates all backend runtime components:

- `backend-api-blue`
- `backend-api-green`
- `backend-job-dispatch`
- `backend-job-cleanup`

The API and job images receive the same immutable backend tag. For Postmark
configuration, delivery checks, and token rotation, see
[Postmark operations](./postmark.md).

## 1. Preconditions

Confirm the local backend worktree is clean because the builder refuses dirty
source:

```bash
git -C ../backend status --short
```

Confirm AWS identity and host connectivity:

```bash
aws sts get-caller-identity
ansible morrowpal_hosts -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml -m ping
```

The AWS account must be `384078510608`.

The shared deploy playbook requires the sibling frontend checkout to read public
web runtime settings, including for a backend-only deployment. Use
`--frontend-directory PATH` if that checkout is elsewhere.

## 2. Build and deploy to staging

The builder runs backend unit, API and job tests, then creates local Linux AMD64
API and job images with one immutable `build-N-GITSHA` tag. It exports
`BACKEND_TAG` when sourced.

```bash
source shared/scripts/build-images.sh backend
shared/scripts/deploy-images.sh staging backend "$BACKEND_TAG" --dry-run
```

The build reserves the component's next number. Commit its counter file even if
building fails. The dry run validates the AWS account, Region, stack outputs,
instance identity, Elastic IP, inventory, overlay, and available image sources.
It prints the deployment plan using read-only AWS calls.

Deploy and test in staging:

```bash
shared/scripts/deploy-images.sh staging backend "$BACKEND_TAG"
```

The command publishes the local release images, verifies digests and scans, then
runs the shared Ansible playbook with the validated inventory and configuration.
Critical/high findings stop the deployment before any host action. Published
images with the requested immutable tag support retries and rollback. The
playbook checks container and public readiness before completing.

Keep tested local images for the first production publication. Production work
starts after staging validation, the final parity audit and explicit approval.
The production deployment preserves the selected tag and image digest.

## 3. Preview the approved production deployment

```bash
shared/scripts/deploy-images.sh prod backend "$BACKEND_TAG" --confirm-production --dry-run
```

The deployment preserves the currently recorded app image tag; a backend
update does not require an app tag.

Non-API infrastructure changes are reconciled in place. API services are
excluded from the generic Compose reconciliation and always use the rolling
blue-green path when their image or Compose configuration changes. An Envoy
configuration change recreates the single Envoy container and can cause a
brief edge interruption.

## 4. Deploy to production

```bash
shared/scripts/deploy-images.sh prod backend "$BACKEND_TAG" --confirm-production
```

The shared playbook's rolling release command performs these steps:

1. Routes traffic away from one API slot.
2. Waits for active requests to drain.
3. Replaces that slot and waits for `/ready`.
4. Restores balanced traffic.
5. Repeats the process for the other API slot.
6. Updates both job containers after both API slots are healthy.

When the API Compose configuration changed without a new backend image, the
same sequence force-recreates each slot with its existing immutable tag. This
applies new environment variables, secrets, mounts, and other container
settings without taking both API slots down together.

If an image update fails readiness, the prior immutable tag is restored while
the other slot continues serving traffic. If a configuration-only recreation
fails, the other slot remains active and the deployment stops; restore the
previous Compose configuration before retrying.

## 5. Verify production

```bash
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://api.morrowpal.com/ready
```

Exercise one authenticated API flow before declaring the release complete.

## Production rollback

Select a retained backend tag in production ECR. Deploy it with:

```bash
PREVIOUS_BACKEND_TAG='build-N-GITSHA'

shared/scripts/deploy-images.sh prod backend "$PREVIOUS_BACKEND_TAG" --confirm-production
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
