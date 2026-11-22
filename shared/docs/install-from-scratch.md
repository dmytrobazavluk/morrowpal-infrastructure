# Create resources and prepare a new host

Use this guide for a new installation after completing the
[shared prerequisites](./installation-prerequisites.md) and the selected
environment's README linked there. Both current environments already exist.
Do not recreate their stacks or retained resources; use the update or
host-replacement procedure instead. Production writes require completed staging validation,
the final parity audit, and explicit approval.

The initial deployment uses one guarded command with all three component tags.
Routine component updates use the separate update guides afterward.

## 1. Select and load the environment

Run commands in one Bash shell from `infrastructure`. The rendered file contains
public infrastructure bindings, not secret values:

```bash
set -euo pipefail
ENVIRONMENT=staging
CONFIRMATION=()
case "$ENVIRONMENT" in
  staging) ;;
  prod) CONFIRMATION=(--confirm-production) ;;
  *) printf 'Select staging or prod.\n' >&2; exit 1 ;;
esac
INVENTORY="environments/$ENVIRONMENT/inventory.ini"
VARS="environments/$ENVIRONMENT/vars.yml"
CONFIG_FILE=$(mktemp)
ansible localhost -i localhost, --connection local \
  -m ansible.builtin.template \
  -a "src=shared/runtime/cloudformation.env.j2 dest=$CONFIG_FILE mode=0600" \
  -e "@$VARS"
source "$CONFIG_FILE"
rm -f -- "$CONFIG_FILE"
test "$MORROWPAL_ENVIRONMENT" = "$ENVIRONMENT"
test "$MORROWPAL_STACK_PREFIX" = "morrowpal-$ENVIRONMENT"
REGION="$MORROWPAL_AWS_REGION"
STACK_PREFIX="$MORROWPAL_STACK_PREFIX"
test "$(aws sts get-caller-identity --query Account --output text --region "$REGION")" \
  = "$MORROWPAL_AWS_ACCOUNT_ID"
```

The VPC and public subnet must already exist in the selected Region and AZ.
Before the prerequisites stack exists, keep the required security-group field
as an explicit pending value. Before the Elastic IP exists, keep the public-IP
field and inventory address equal to the same pending value. Never borrow
another environment's IDs or address. These pending values are not host targets;
replace them with outputs at the handoffs below.

Run local validation before each resource change:

```bash
scripts/validate-environments.sh
bash shared/scripts/validate-local.sh
```

## 2. Create and review one change set at a time

Use the following recipe for each row in the installation order below. Set
`STACK_KIND`, `CHANGE_SET`, and `STACK_OPTIONS` for that row. The wrapper validates
the selected inventory/overlay, account, Region, network, and required cross-stack
outputs. It never executes the change set.

For the first row, replace the example public-key path and SSH CIDR with your
reviewed values. Supply only the public key; retain the private key locally:

```bash
STACK_KIND=prerequisites
CHANGE_SET=initial-prerequisites
STACK_OPTIONS=(--ssh-public-key-file "../morrowpal-$ENVIRONMENT-01.pem.pub" \
  --ssh-ingress-cidr 203.0.113.1/32)
```

For every subsequent row, set its kind and a unique change-set name, and reset
`STACK_OPTIONS=()`. For example, the next row uses `STACK_KIND=ecr` and
`CHANGE_SET=initial-ecr`. Production's existing security group and key are not
to be recreated by following the first-row example.

Validate, create, and inspect the selected change set:

```bash
aws cloudformation validate-template \
  --template-body "file://shared/cloudformation/$STACK_KIND.yml" \
  --region "$REGION" >/dev/null
shared/scripts/morrowpal-infrastructure-change-set.sh \
  "$ENVIRONMENT" "$STACK_KIND" "$CHANGE_SET" \
  "${CONFIRMATION[@]}" "${STACK_OPTIONS[@]}" --dry-run
shared/scripts/morrowpal-infrastructure-change-set.sh \
  "$ENVIRONMENT" "$STACK_KIND" "$CHANGE_SET" \
  "${CONFIRMATION[@]}" "${STACK_OPTIONS[@]}"
aws cloudformation wait change-set-create-complete \
  --stack-name "$STACK_PREFIX-$STACK_KIND" --change-set-name "$CHANGE_SET" \
  --region "$REGION"
aws cloudformation describe-change-set \
  --stack-name "$STACK_PREFIX-$STACK_KIND" --change-set-name "$CHANGE_SET" \
  --include-property-values --region "$REGION" --output json
```

Review the stack ARN, CREATE change-set type, parameters, tags, resolved
properties, IAM scope, and resource actions. A fresh installation should add
only the resources described in its row. Stop on an UPDATE change set,
replacement, deletion, unexpected resource, or reference to another environment.
An existing stack or retained secret/volume requires a recovery plan.

Only after reviewing that specific change set, execute it and wait:

```bash
aws cloudformation execute-change-set \
  --stack-name "$STACK_PREFIX-$STACK_KIND" --change-set-name "$CHANGE_SET" \
  --region "$REGION"
aws cloudformation wait stack-create-complete \
  --stack-name "$STACK_PREFIX-$STACK_KIND" --region "$REGION"
aws cloudformation describe-stacks \
  --stack-name "$STACK_PREFIX-$STACK_KIND" \
  --query 'Stacks[0].Outputs' --region "$REGION" --output table
```

Do not run the recipe as an unattended loop. Complete each output handoff before
creating the next stack.

New EC2 hosts use the exact Amazon Linux release, trusted owner, and architecture
in `shared/ec2-image.json`; the wrapper resolves its Region-local AMI ID and
rejects missing, ambiguous, unavailable, or mismatched images. The policy's
`deprecatedImageExceptionName` permits only that explicitly reviewed deprecated
release. Changing the release requires reviewing or removing that exception.
There is no fallback to a latest-image alias. Routine updates retain the
existing instance's AMI; this policy does not replace an existing host.
For a replacement candidate, use the [host-replacement guide](./replace-host.md)
and its CREATE-only `--candidate-suffix` operation rather than changing the
active-stack setting to a nonexistent host.

| Order | Stack kind | Expected additions and handoff |
| --- | --- | --- |
| 1 | `prerequisites` | Dedicated security group and imported recovery public key. Copy `SecurityGroupId` and `KeyPairName` into the selected overlay. Check the imported key fingerprint. |
| 2 | `ecr` | Four immutable repositories: backend API, backend jobs, app, and website. |
| 3 | `ec2-access` | EC2 role and instance profile with pull access scoped to the environment's repositories. |
| 4 | `ec2` | Amazon Linux 2023 x86_64 host and encrypted root storage. Check the selected AMI, subnet, AZ, group, key, capacity, and instance-profile binding. |
| 5 | `public-ip` | Dedicated Elastic IP and association to the selected instance. Update the selected inventory address, `morrowpal_public_ipv4`, and `morrowpal_tls_expected_ipv4` together. |
| 6 | `mysql-storage` | Retained encrypted data volume and attachment to the selected instance in its AZ. Record `VolumeId` for host preparation. |
| 7 | `runtime-secrets` | Six secrets and access scoped to the selected EC2 role. Populate provider values using the environment prerequisite checklist. |
| 8 | `system-alerts` | Environment SNS topic, selected email subscriptions, and scoped publishing/KMS policy. Set recipients below and confirm subscriptions. |
| 9 | `http-validation-ingress` | Port 80 certificate-validation ingress on the selected security group. |

Before row 8, set the selected environment's alert recipients. Replace the
example address; leave optional recipients empty if unused:

```bash
export MORROWPAL_PRIMARY_ALERT_EMAIL=alerts@example.com
export MORROWPAL_SECONDARY_ALERT_EMAIL=''
export MORROWPAL_TERTIARY_ALERT_EMAIL=''
```

Compare `SystemAlertsTopicArn` with `morrowpal_system_alerts_topic_arn` in the
selected overlay. Confirm every subscription before starting the backend.
Do not copy production recipients into staging without a deliberate choice.

## 3. Verify the stable target and prepare the host

After the Elastic IP handoff, check its association and the instance's identity
against the selected stack outputs. Re-run a guarded read-only resolution with
the updated inventory/overlay before connecting:

```bash
shared/scripts/morrowpal-infrastructure-change-set.sh \
  "$ENVIRONMENT" http-validation-ingress verify-host-binding \
  "${CONFIRMATION[@]}" --dry-run
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -m ping
```

Use the stable inventory address throughout; no temporary IP override is needed.
The installation playbooks below take the inventory and overlay explicitly.
Unlike the wrappers, direct Ansible does not independently validate AWS bindings.

```bash
ansible-playbook shared/playbooks/install-docker.yml -i "$INVENTORY" -e "@$VARS"
ansible-playbook shared/playbooks/install-docker-compose.yml -i "$INVENTORY" -e "@$VARS"
ansible-playbook shared/playbooks/prepare-host.yml -i "$INVENTORY" -e "@$VARS"
ansible-playbook shared/playbooks/prepare-mysql.yml -i "$INVENTORY" -e "@$VARS"
```

Read the data volume from its stack, then inspect its attachment:

```bash
MYSQL_VOLUME_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_PREFIX-mysql-storage" \
  --query 'Stacks[0].Outputs[?OutputKey==`VolumeId`].OutputValue | [0]' \
  --output text --region "$REGION")
test -n "$MYSQL_VOLUME_ID" && test "$MYSQL_VOLUME_ID" != None
aws ec2 describe-volumes --volume-ids "$MYSQL_VOLUME_ID" \
  --region "$REGION" --output json
```

Confirm the volume tags, AZ, and attachment match the selected environment and
instance before formatting. For a new installation the data volume must be
empty. A filesystem or retained database means this is recovery, not a fresh
installation. The playbook formats an empty device as XFS, persists the mount,
creates the MySQL directory, and prepares a swap file on the encrypted volume.

This command uses fresh-install behavior. Retained-volume recovery requires
`morrowpal_require_existing_mysql_filesystem=true` and the recorded
`morrowpal_expected_mysql_filesystem_uuid`, as described in the
[host-replacement guide](./replace-host.md); it must not initialize an empty disk.

For a new, empty data volume:

```bash
ansible-playbook shared/playbooks/prepare-storage.yml \
  -i "$INVENTORY" -e "@$VARS" \
  -e "morrowpal_mysql_volume_id=$MYSQL_VOLUME_ID"
```

## 4. Configure DNS and TLS

At IONOS, set A records for all six names in the selected overlay's
`morrowpal_domains` to the new Elastic IP. Do not modify the other environment's
records. These manual DNS changes are outside CloudFormation. Ensure every
certificate name resolves to that address and has no AAAA record until IPv6 is
supported. Port 80 ingress must exist before issuance.

Choose a certificate registration email and issue the certificate:

```bash
ansible-playbook shared/playbooks/prepare-tls.yml \
  -i "$INVENTORY" -e "@$VARS" \
  -e morrowpal_certbot_email=admin@example.com
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'systemctl status morrowpal-certbot-renew.timer --no-pager'
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'certbot renew --dry-run'
```

Replace the example email before running. The TLS playbook checks DNS against
the selected overlay. The [shared TLS guide](./tls.md) describes renewal,
permissions, certificate loading, and verification for both environments.

## 5. Record preparation and select images

Record stack outputs, completed provider setup and SNS confirmations, storage
identity, DNS records, certificate checks, and any manual metadata tagging.
Do not record secret values. Re-run local validation after the overlay handoffs.
The [staging operations guide](../../environments/staging/README.md) documents
instance-profile/root-volume/network tags, budget setup, and the staging-only
nightly shutdown stack. Include those controls in a staging installation.

Build the initial release images locally using the build sections of the
[backend](./update-backend.md), [app](./update-app.md), and
[website](./update-website.md) guides. Do not run their individual deployments
against a host without recorded tags. Keep each exported tag in this shell and
commit the component counters after building, including failed builds.

For a production installation, select the already-tested staging tags and retain
the same local images. Do not rebuild for production. Missing images are not
automatically copied from staging ECR. The production approval gate still applies.

Set the selected tags explicitly if resuming in a new shell:

```bash
BACKEND_TAG='build-N-GITSHA'
APP_TAG='build-N-GITSHA'
WEBSITE_TAG='build-N-SOURCESHA'
```

Replace each placeholder with its actual immutable tag. The component numbers
can differ; the API and both jobs share the backend tag.

## 6. Publish and deploy the initial images together

Preview the complete target and image plan without registry writes or host access:

```bash
shared/scripts/deploy-images.sh "$ENVIRONMENT" initial \
  "$BACKEND_TAG" "$APP_TAG" "$WEBSITE_TAG" "${CONFIRMATION[@]}" --dry-run
```

The wrapper checks the account, Region, instance, role, network, Elastic IP,
inventory, overlay, and all four image sources. It accepts no Ansible target
overrides. Use `--frontend-directory PATH` if the frontend checkout is elsewhere.

Apply the reviewed plan with the same tags:

```bash
shared/scripts/deploy-images.sh "$ENVIRONMENT" initial \
  "$BACKEND_TAG" "$APP_TAG" "$WEBSITE_TAG" "${CONFIRMATION[@]}"
```

The command publishes missing local images into the selected immutable ECR
repositories, verifies their digests, and scans all four images before any host
action. Critical/high findings stop the deployment. It revalidates the target,
then invokes the shared playbook once with all three component tags. No images
are built and no build counters change during deployment.

The playbook initializes missing tag files and starts the systemd service,
which resolves secrets at runtime, pulls the selected images, and starts the
containers with readiness checks. If publication or deployment fails, diagnose
the error and retry with the same tags; already-published matching images are
reused. Partial publication can leave images in ECR. Initial installation has no
previous application release to restore automatically.

`--check --diff` can preview the playbook only when all images are already
published. It does not publish missing images; use `--dry-run` for the first
publication preview. The `initial` mode explicitly supplies all component tags;
on an existing host it can update all components, so use single-component modes
for routine releases.

## 7. Verify the installation

```bash
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a '/usr/local/sbin/morrowpal-service status'
ansible morrowpal_hosts -i "$INVENTORY" -e "@$VARS" -b -m command \
  -a 'systemctl status morrowpal --no-pager'
```

Run the selected environment's endpoint and browser checks from all three
component guides. Confirm both API slots and jobs use the backend tag, app and
website use their selected tags, and API weights return to 50/50. Complete live
email, SNS, and controlled-client Firebase notification checks. Readiness alone
does not verify delivery. Record the tested tags/digests and results without
secret values. Use the component update guides for subsequent releases.
