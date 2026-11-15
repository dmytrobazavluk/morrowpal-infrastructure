# Production promotion checklist

Run local commands in Bash from `infrastructure`. This checklist promotes a
release already verified through the [staging checklist](./staging-release-checklist.md).
It is documentation, not approval to perform production work. All boxes below
are initially unchecked. The refactor's first promotion also requires the
template-promotion phases below; routine later releases can mark those phases
not applicable when no stack changes are needed.

## 1. Complete the staging gate and select the release

- [ ] Select the tested infrastructure revision and affected components. Record
  the staging release evidence, exact tags, and manifest digests. Backend API
  and job images share a tag but have separate digests. Component build numbers
  may differ; retain unchanged components' production tags.
- [ ] Complete required staging functional, rollout/rollback, schema, and live
  delivery checks. The deferred controlled-client notification check remains a
  gate. A same-tag deployment or provider console test does not prove rollout
  or application notification delivery.
- [ ] Complete the final parity audit and resolve unexplained differences.
  Document environment values, capacity, external network ownership, and
  staging-only cost controls. Keep the host-replacement execution limitation
  explicit; this checklist does not authorize replacement.
- [ ] Review production database migration compatibility, backup/recovery
  readiness, previous image availability, rollback criteria, maintenance needs,
  and any expected Envoy interruption. An image rollback does not undo schema
  migrations. Resolve compatibility between retained images and shared runtime
  configuration before applying that configuration.
- [ ] Obtain explicit approval for production change-set creation before any
  production write, including image publication. The CLI confirmation flag is
  an execution guard, not a substitute for this approval.

Keep a promotion record in `artifacts/` with the approved scope, revisions,
baseline and selected tags/digests, migration/rollback decisions, reviewed
change sets, approvals, results, and remaining issues. Exclude secret values
and private user data. Do not rotate secrets or provider credentials as a side
effect of promotion.

## 2. Prepare the production target and template changes

Use the account and Region in `environments/prod/vars.yml`. Set the Region below
to that overlay's value; the current production Region is `us-east-2`:

```bash
PRODUCTION_REGION=us-east-2
aws sts get-caller-identity --region "$PRODUCTION_REGION"
git status --short
git diff --check
bash shared/scripts/validate-local.sh
```

- [ ] Verify the reviewed worktree and sibling frontend configuration. Use
  `--frontend-directory PATH` on deployment commands if it is elsewhere.
- [ ] Record current production service/endpoint health, image tags, storage and
  IP identity, and operational alarms using read-only procedures in the
  [production index](../../prod/README.md). Do not change production to obtain
  a healthy baseline; diagnose failures before promotion.
  Resolve unexpected mixed API slot tags before selecting rollback artifacts.
- [ ] For the first template promotion, create change sets using the guarded
  infrastructure wrapper only after phase 1 approval. For example:

```bash
shared/scripts/morrowpal-infrastructure-change-set.sh \
  prod ec2-access REVIEW_NAME --confirm-production --dry-run
shared/scripts/morrowpal-infrastructure-change-set.sh \
  prod ec2-access REVIEW_NAME --confirm-production
```

Use the selected stack kind and a unique reviewed name; do not execute this
example as a blanket instruction to update EC2 access. Review full change-set
details with `--include-property-values`. Confirm account/Region, production
bindings, IAM scope, tags, and every resource action. The initial refactor
requires no resource replacements. Stop on an unexpected create/delete,
replacement, changed AMI, staging reference, or unplanned configuration change.

- [ ] Record the change-set summaries and obtain separate approval for their
  execution. Create and review stacks that depend on new outputs only once
  those outputs are available; do not bypass missing bindings with manual IDs.
- [ ] Execute approved change sets one stack at a time in dependency order:
  EC2 access before consumers of its outputs, EC2 before instance consumers.
  Wait for each stack to complete and verify drift/focused resource identity
  and readiness after every change. Preserve the existing instance, retained
  data, Elastic IP allocation, and provider identities.

The deployment guard needs the promoted stack outputs. Do not use its first
production invocation to bypass an incomplete template promotion. Changes to
host files use the [infrastructure update guide](./update-infrastructure.md),
not CloudFormation, and require their own reviewed deployment scope.

## 3. Prepare exactly the tested images

- [ ] Keep the tested local images available, or verify that production ECR
  already contains the recorded tag **and matching digest**. Matching tag text
  alone is insufficient. The production wrapper does not retrieve an image
  missing both locally and in production ECR from staging ECR automatically.
  If needed, implement and test retrieval by staging digest before proceeding.
- [ ] Do not run the builder, increment counters, relabel an unrelated image,
  or choose a newer image just because it exists. A rebuild is a new release
  requiring staging verification.
- [ ] Set only the affected component tags to their recorded tested values.
  For a backend release, for example:

```bash
BACKEND_TAG='build-N-GITSHA'
```

Replace the placeholder with the actual tested tag. For existing production
images, compare metadata with the staging record before approving deployment:

```bash
aws ecr describe-images --repository-name morrowpal/prod/backend-api \
  --image-ids "imageTag=$BACKEND_TAG" --region "$PRODUCTION_REGION" \
  --query 'imageDetails[0].{Tag:imageTags,Digest:imageDigest}' --output json
```

Repeat for backend jobs or affected app/website images. An absent tag needs
publication from the tested local image; it is not permission to build a
replacement. Stop on an existing-tag digest mismatch.

## 4. Preview and obtain rollout approval

After the template promotion is complete, use the affected component's guarded
dry run, for example:

```bash
shared/scripts/deploy-images.sh prod backend "$BACKEND_TAG" \
  --confirm-production --dry-run
```

- [ ] Check the target, tag/digest, image availability, and publication plan
  against the approved record. Existing images must match their staging
  digests; local images awaiting publication must be the tested artifacts.
- [ ] If all affected images are already published, use `--check --diff` to
  preview Ansible changes. That mode requires published images and connects
  to the host; `--dry-run` performs no registry writes or host connection.
- [ ] Review shared host configuration alongside the selected image. A
  single-component release may reconcile shared configuration, including
  rolling API slots or recreating Envoy when those files change. Resolve every
  unexpected action and agree on the rollout order for the first promotion.
- [ ] Obtain explicit approval for image publication and application rollout.
  Publication and deployment occur together in the wrapper. There is no
  separately authorized production push implied by completing staging.

## 5. Deploy and verify one affected component at a time

Only after rollout approval, for the backend example:

```bash
shared/scripts/deploy-images.sh prod backend "$BACKEND_TAG" --confirm-production
```

Use `app "$APP_TAG"` or `website "$WEBSITE_TAG"` for those components. Use
`infrastructure` without a tag only for an approved host-configuration change.
Do not use the fresh-host `initial` mode for a routine component promotion.

- [ ] Require successful digest and vulnerability-scan checks before host
  deployment. Critical/high findings block the wrapper; do not bypass them.
- [ ] Monitor readiness during rollout. Verify backend slots roll one at a
  time, weights return to 50/50, and jobs use the selected backend tag. Check
  the affected component's [backend](./update-backend.md), [app](./update-app.md),
  or [website](./update-website.md) guide for detailed verification.
- [ ] Verify service/container state, all public readiness endpoints, public
  TLS, affected authenticated flows and dispatch/cleanup behavior, production API/Firebase settings,
  live provider delivery when affected, and operational alarms/logs. Avoid
  production mutations solely to repeat staging fault-injection tests.
- [ ] Confirm the published image digests equal the staging record and unchanged
  components retain their approved tags. Check stack drift/focused resource
  identity and record final health before declaring completion.

## 6. Roll back on the agreed failure gates

- [ ] Stop further promotions if publication, scanning, deployment, readiness,
  migration, or functional checks fail. Inspect the wrapper/playbook result;
  do not assume an automatic rollback restored everything.
- [ ] When schema compatibility permits, redeploy the previous retained tag
  through the same guarded wrapper. For example:

```bash
shared/scripts/deploy-images.sh prod backend "$PREVIOUS_BACKEND_TAG" \
  --confirm-production
```

Set `PREVIOUS_BACKEND_TAG` from the production baseline first. Use the matching
app/website command when applicable. Failed configuration changes require a
reviewed file reversal and redeployment; CloudFormation reversal requires its
own reviewed change set. If the schema is incompatible, follow the approved
recovery plan rather than assuming the prior image is safe.

- [ ] Recheck readiness, functional behavior, tags/digests, and alarms after
  rollback. Record the final state and unresolved issues.
- [ ] Keep production running. Use the staging lifecycle wrapper only to stop
  staging after testing; never apply its shutdown policy to production.

## Differences from the staging checklist

| Staging phase | Production counterpart | Reason |
| --- | --- | --- |
| Select change, validate locally | Select the exact tested revision/artifacts, complete parity and approvals | Promotion reuses evidence and immutable artifacts; it does not build a new release. |
| Start staging and capture baseline | Capture the already-running production baseline | Production has no on-demand start/stop cycle. |
| Test infrastructure changes | Review no-replacement change sets, then separately approve/apply in dependency order | Production preservation and the first shared-output migration require explicit review gates. |
| Build changed components, publish, deploy | Reuse tested tags/digests and publish/deploy only after approval | Same images cross Region-specific ECR repositories; missing artifacts must be recovered, not rebuilt. |
| Exercise behavior and rollback | Verify production behavior and keep rollback ready; use it on agreed failure gates | Deliberate failure/rollback exercises belong in staging; production still needs schema-safe recovery. |
| Record results and stop staging | Record results and leave production running | Only staging has a nightly shutdown and retained-cost lifecycle. |

Environment differences are values in matching overlays: account/Region/AZ,
resource paths, domains, capacity, provider identities, and recipients. The
shared templates, deployment guards, playbooks, and component release behavior
remain common. Keep each checklist item's result in the promotion record;
no unchecked required item is waived by this comparison table.
