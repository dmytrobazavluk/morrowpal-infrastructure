# Create resources and prepare a new host

Use this guide for a new installation after completing the
[shared prerequisites](./installation-prerequisites.md) and the selected
environment's checklist. Both current environments already exist. Do not
recreate their stacks or retained resources; use the update or host-replacement
procedure instead. Production writes require completed staging validation,
the final parity audit, and explicit approval.

This guide ends before initial image deployment. That command remains gated
until the supported bootstrap path is implemented and tested.

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
creates the MySQL directory, and prepares a swap file on the encrypted volume:

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
the selected overlay. The [production TLS guide](../../prod/docs/tls.md)
describes renewal architecture; its production commands are not staging steps.

## 5. Record preparation and stop before deployment

Record stack outputs, completed provider setup and SNS confirmations, storage
identity, DNS records, certificate checks, and any manual metadata tagging.
Do not record secret values. Re-run local validation after the overlay handoffs.
The [staging operations guide](../../environments/staging/README.md) documents
instance-profile/root-volume/network tags, budget setup, and the staging-only
nightly shutdown stack. Include those controls in a staging installation.

**Initial deployment gate:** the routine deployment wrapper accepts one
component tag per invocation; a new host needs all three component tags together.
The supported bootstrap command is a pending implementation step. Stop here.
Do not use three routine component deployments or an unguarded deploy playbook
as a substitute. No application is expected to be running at this point.
