# Update the Backend

Run commands from `infrastructure`.

Production operations below are deferred until staging validation and the final
parity audit are complete and production work is explicitly approved.
Select the deployment target with the matching Ansible inventory and
environment variable file.

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
web runtime settings, including for a backend-only deployment. Set
`morrowpal_frontend_directory` if that checkout is elsewhere.

## 2. Build locally, push to staging, and test

The builder runs backend unit, API and job tests, then creates local Linux AMD64
API and job images with one immutable `build-N-GITSHA` tag. It exports
`BACKEND_TAG` when sourced.

```bash
source shared/scripts/build-images.sh backend
shared/scripts/push-images.sh staging backend "$BACKEND_TAG"
```

The build command reserves the next number in `build-numbers/backend` and
creates local images. Commit that counter even if building fails. The push
command uploads the images to staging's ECR repositories, verifies their digests
and waits for vulnerability scans. Critical/high findings fail this step.
See [build number coordination](../../build-numbers/README.md).

Deploy and test in staging:

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml \
  -e "morrowpal_image_tag=$BACKEND_TAG"
```

After staging validation, the final parity audit, and explicit production
approval, push the same local images to production:

```bash
shared/scripts/push-images.sh prod backend "$BACKEND_TAG" --confirm-production
```

Keep the tested local release images until promotion. The production push
preserves the tag and verifies the digest against the staging push.
`BACKEND_TAG` identifies the backend build. Proceed with deployment below
after the push succeeds and deployment is approved.

Registry-to-registry recovery for missing local images is planned in Step 54a.1.
If the local release images are missing, stop until they can be recovered from
staging with their verified digests.

## 3. Preview the production deployment (after approval and promotion)

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
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

## 4. Deploy to production

```bash
ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
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

## 5. Verify production

```bash
ansible morrowpal_hosts -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'
curl --fail --show-error --silent https://api.morrowpal.com/ready
```

Exercise one authenticated API flow before declaring the release complete.

## Production rollback

Select a previously retained backend tag and deploy it through the same
playbook:

```bash
PREVIOUS_BACKEND_TAG='build-N-GITSHA'

ansible-playbook shared/playbooks/deploy.yml \
  -i environments/prod/inventory.ini \
  -e @environments/prod/vars.yml \
  -e "morrowpal_image_tag=$PREVIOUS_BACKEND_TAG"
```

The ECR lifecycle policy retains the five most recent `build-*` images by
default.
