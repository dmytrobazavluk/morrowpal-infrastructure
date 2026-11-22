# Staging release checklist

Run commands in Bash from `infrastructure/aws`. This checklist targets staging only
and ends before production promotion. Use it for an existing staging host;
[first installation](./install-from-scratch.md) and
[host replacement](./replace-host.md) are separate workflows.

Current refactor decision, 2026-11-20: the user completed sign-in/out, live email
and reply-creation checks and accepted deferring browser notification delivery
to production. Keep that delivery check unverified; its deferral does not block
this refactor's staging gate. Other required checks and production approvals
remain in place.

## 1. Choose the change and prepare a release record

- [ ] Record the infrastructure revision and affected components: backend, app,
  website, CloudFormation stacks, or host configuration.
- [ ] Confirm the staging account, Region, inventory, and overlay in
  `environments/staging/vars.yml` and `inventory.ini`. Use that account's AWS
  credentials; unset conflicting Ansible connection overrides if the wrapper
  rejects them.
- [ ] Set the Region below to the overlay's `morrowpal_aws_region`. The current
  staging Region is `us-east-1`.

```bash
STAGING_REGION=us-east-1
aws sts get-caller-identity --region "$STAGING_REGION"
git status --short
git diff --check
bash shared/scripts/validate-local.sh
```

- [ ] Stop on failed checks. Review the intended file changes before deployment.
- [ ] Confirm the sibling frontend checkout is available for public runtime
  configuration, even for backend-only releases. Use `--frontend-directory PATH`
  on deployment commands if necessary.
- [ ] Allow time for verification and rollback before the nightly **1 AM
  America/Chicago** shutdown. Avoid concurrent deployments/lifecycle operations.
  A test waiting for delayed dispatch remains incomplete until delivery occurs.

Keep a tracked release record in `shared/docs/releases/` with revisions, previous/selected image
tags and digests, change-set IDs, checks/results, outstanding items, and final
staging state. Exclude credentials, verification codes, private key contents,
and private user data. Mark steps unrelated to the change as not applicable.

## 2. Start staging and capture the baseline

```bash
shared/scripts/staging-lifecycle.sh status
shared/scripts/staging-lifecycle.sh start --dry-run
shared/scripts/staging-lifecycle.sh start
shared/scripts/staging-lifecycle.sh status
curl --fail --silent --show-error https://api.staging.morrowpal.com/ready
curl --fail --silent --show-error https://app.staging.morrowpal.com/ready
curl --fail --silent --show-error https://staging.morrowpal.com/ready
ansible morrowpal_hosts -i environments/staging/inventory.ini \
  -e @environments/staging/vars.yml -b -m command \
  -a 'docker ps'
```

- [ ] Record the previous API blue/green, job, app, and website tags. If API slot
  tags differ, investigate before choosing a rollback tag.
- [ ] Confirm baseline health and that the selected rollback images remain
  available. Stop and diagnose an unhealthy baseline before release testing.
- [ ] Review database migrations and confirm whether the previous backend is
  compatible with the post-migration schema. An image rollback does not reverse
  migrations. Have a recovery plan before testing incompatible schema changes.

## 3. Apply infrastructure changes when included

- [ ] For CloudFormation changes, use
  `shared/scripts/morrowpal-infrastructure-change-set.sh staging STACK_KIND REVIEW_NAME --dry-run`,
  then create the change set through that wrapper. Supply the kind's required
  public inputs as described in the [installation guide](./install-from-scratch.md)
  and [staging operations guide](../../environments/staging/README.md).
- [ ] Inspect the full change set, including resolved property values, resource
  actions, replacements, IAM scope, environment tags, and cross-stack bindings.
  Execute only the reviewed change set, wait for completion, and verify its
  outputs and readiness before continuing. A replacement requires its separate
  supported procedure; do not improvise it during routine release testing.
- [ ] For Compose, Envoy, service-script, or systemd changes, preview and deploy
  through the [shared infrastructure guide](./update-infrastructure.md):

```bash
shared/scripts/deploy-images.sh staging infrastructure --check --diff
shared/scripts/deploy-images.sh staging infrastructure
```

Do not apply an infrastructure deployment just because it appears here: run it
only when host configuration is part of the selected change. It keeps recorded
application tags. Envoy recreation can briefly interrupt public traffic.

## 4. Build only changed components and deploy

Choose the relevant component guide:

| Component | Local build | Exported tag | Guide |
| --- | --- | --- | --- |
| Backend | `source shared/scripts/build-images.sh backend` | `BACKEND_TAG` | [Backend](./update-backend.md) |
| App | `source shared/scripts/build-images.sh app 1.1.0` | `APP_TAG` | [App](./update-app.md) |
| Website | `source shared/scripts/build-images.sh website` | `WEBSITE_TAG` | [Website](./update-website.md) |

- [ ] Choose the app's actual semantic version when building it. Backend/app
  source worktrees must be clean. Stop if any build fails; commit its reserved
  counter even on failure. Do not build an unchanged component merely to align
  its number with another component.
- [ ] For a rehearsal using an existing release, set its recorded immutable tag
  instead of rebuilding. It must be available locally or in staging ECR.
- [ ] Use the affected component's guarded dry run, then deployment. For example:

```bash
shared/scripts/deploy-images.sh staging backend "$BACKEND_TAG" --dry-run
shared/scripts/deploy-images.sh staging backend "$BACKEND_TAG"
```

Use `app "$APP_TAG"` or `website "$WEBSITE_TAG"` for those components. The wrapper
publishes missing local images, verifies digests and scans, validates the target
again, and invokes Ansible. Critical/high findings prevent host deployment.
`--check --diff` requires already-published images; `--dry-run` previews a new
publication without registry writes or a remote connection.

- [ ] Record each selected component tag and its ECR digest; backend API and job
  images have the same tag but separate digests. Use read-only metadata queries,
  for example:

```bash
aws ecr describe-images --repository-name morrowpal/staging/backend-api \
  --image-ids "imageTag=$BACKEND_TAG" --region "$STAGING_REGION" \
  --query 'imageDetails[0].{Tag:imageTags,Digest:imageDigest}' --output json
```

Repeat for `backend-job` with `BACKEND_TAG`, or the affected `app`/`website`
repository with its tag. Preserve tested local images for later approved
production publication. Deployment never builds images or increments counters.

## 5. Verify behavior and exercise rollback

- [ ] Repeat all three public readiness checks and inspect service/container
  status. Confirm unchanged components retained their tags.
  For a same-tag rehearsal, compare container IDs as well: Ansible command tasks
  can report changed when invoking a release helper that keeps the existing
  container. The task count alone does not prove a container replacement.
- [ ] For backend changes, monitor readiness during the rolling replacement,
  confirm only one API slot is replaced at a time, both slots return to 50/50,
  and both jobs use the selected tag. A successful no-op deployment does not
  prove a rolling replacement occurred. Use the rollout evidence/checks in the
  [backend guide](./update-backend.md).
- [ ] Exercise an authenticated API flow and affected dispatch/cleanup behavior.
- [ ] For app changes, verify staging API/Firebase configuration, initial load,
  sign-in, API action, refresh, local persistence, sign-out, client routing,
  and CORS using the [app guide](./update-app.md).
- [ ] For website changes, verify routes, www redirect, desktop/mobile layout,
  store links, and the email confirmation flow using the
  [website guide](./update-website.md).
- [ ] Verify affected live Postmark email, confirmed SNS delivery, and Firebase
  notification registration/delivery using controlled staging accounts/devices
  and the [Firebase operations guide](./firebase-app-notifications.md).
  Use the normal dispatch path; do not substitute a provider console test for
  application delivery or silently change scheduling data to accelerate it.
  For the current refactor, browser notification delivery is explicitly deferred
  under the user decision above. Do not mark it passed without observed delivery.
- [ ] Exercise rollback for affected components using the previous tested tags
  and their guide. For backend, after confirming schema compatibility:

```bash
shared/scripts/deploy-images.sh staging backend "$PREVIOUS_BACKEND_TAG"
```

Set `PREVIOUS_BACKEND_TAG` from the baseline record before running. Use the
equivalent app/website command when applicable. Repeat readiness and affected
functional checks after rollback; then restore and recheck the selected release
if that is the intended final staging state. For host configuration rollback,
review the reversal and use the infrastructure guide. CloudFormation reversal
requires its own reviewed change set.

## 6. Record results and stop staging

- [ ] Record final tags/digests, readiness and functional results, rollback
  evidence, failures, and pending checks. A pending required check means the
  release is not ready for promotion. Earlier refactor tests are supporting
  evidence, not proof that this release passed.
- [ ] After testing, shut staging down through its guarded lifecycle command:

```bash
shared/scripts/staging-lifecycle.sh stop --dry-run
shared/scripts/staging-lifecycle.sh stop
shared/scripts/staging-lifecycle.sh status
```

- [ ] Confirm the final state is stopped and record it. Storage, Elastic IP,
  secrets, and images remain allocated. If a delayed test needs more runtime,
  record it as pending and plan around the nightly shutdown.
- [ ] Review and commit the intended implementation and build-counter changes.
  Production promotion requires the
  [promotion checklist](./production-promotion-checklist.md), final parity audit,
  completed delivery checks, and explicit approval; this checklist performs no
  production action.
