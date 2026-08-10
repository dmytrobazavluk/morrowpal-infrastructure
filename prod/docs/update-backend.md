# Update the Backend

Run commands from `infrastructure/prod`.

This procedure updates all backend runtime components:

- `backend-api-blue`
- `backend-api-green`
- `backend-job-dispatch`
- `backend-job-cleanup`

The API and job images receive the same immutable backend tag. For Postmark
configuration, delivery checks, and token rotation, see
[Postmark operations](./postmark.md).

## 1. Preconditions

Confirm the local backend worktree is clean because the publisher refuses dirty
source:

```bash
git -C ../../backend status --short
```

Confirm AWS identity and host connectivity:

```bash
aws sts get-caller-identity
ansible production -m ping
```

The AWS account must be `384078510608`.

## 2. Publish the backend images

Choose a positive build number greater than the latest published backend build:

```bash
./scripts/publish-images.sh BUILD_NUMBER
```

The publisher:

- Runs the backend test and build checks.
- Builds Linux AMD64 API and shared job images.
- Pushes both images with the same immutable `build-N-GITSHA` tag.
- Waits for ECR vulnerability scans.
- Rejects critical or high findings.
- Refuses the wrong AWS account, a dirty backend worktree, an existing tag, or
  a non-increasing build number.

Assign the exact published tag to a shell variable, replacing the example
value:

```bash
BACKEND_TAG='build-N-GITSHA'
```

## 3. Preview the deployment

```bash
ansible-playbook ./playbooks/deploy.yml \
  --check \
  --diff \
  -e "morrowpal_image_tag=$BACKEND_TAG"
```

The deployment preserves the currently recorded app image tag; a backend
update does not require an app tag.

Non-API infrastructure changes are reconciled in place. API services are
excluded from the generic Compose reconciliation and always use the rolling
blue-green path when their image or Compose configuration changes. An Envoy
configuration change recreates the single Envoy container and can cause a
brief edge interruption.

## 4. Deploy

```bash
ansible-playbook ./playbooks/deploy.yml \
  -e "morrowpal_image_tag=$BACKEND_TAG"
```

The rolling release command performs these steps:

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

## 5. Verify

```bash
ansible 01 -b -m command -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://api.morrowpal.com/ready
```

Exercise one authenticated API flow before declaring the release complete.

## Rollback

Select a previously retained backend tag and deploy it through the same
playbook:

```bash
PREVIOUS_BACKEND_TAG='build-N-GITSHA'

ansible-playbook ./playbooks/deploy.yml \
  -e "morrowpal_image_tag=$PREVIOUS_BACKEND_TAG"
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
