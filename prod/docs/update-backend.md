# Update the Backend

Run commands from `infrastructure/prod`.

This procedure updates all backend runtime components:

- `backend-api-blue`
- `backend-api-green`
- `backend-job-dispatch`
- `backend-job-cleanup`

The API and job images receive the same immutable backend tag.

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

The app tag may be omitted after `/opt/morrowpal/app-image-tag` has been
initialized. If this is also the first app deployment, follow
[Update the app](./update-app.md) and pass both tags.

Infrastructure changes are reconciled in place: new services are created and
only services with changed Compose definitions are recreated. An Envoy
configuration change recreates only the single Envoy container and can cause a
brief edge interruption. When only image tags change, the backend update uses
the rolling blue-green path.

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

If an API slot fails readiness, the prior immutable tag is restored while the
other slot continues serving traffic.

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
