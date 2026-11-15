# Staging operations

Run commands from `infrastructure` with AWS credentials for the account and
Region configured in `environments/staging/vars.yml`.

For a new environment, begin with the
[shared installation prerequisites](../../shared/docs/installation-prerequisites.md)
and [staging-specific checklist](./installation-prerequisites.md).
Then follow [resource creation and host preparation](../../shared/docs/install-from-scratch.md),
which stops before the pending initial-deployment implementation.

For Compose, Envoy, service-script, or systemd changes, follow the
[shared infrastructure update procedure](../../shared/docs/update-infrastructure.md)
with `ENVIRONMENT=staging`.

Component releases follow the shared guides, starting with their staging steps:

- [Update the backend](../../shared/docs/update-backend.md)
- [Update the app](../../shared/docs/update-app.md)
- [Update the website](../../shared/docs/update-website.md)

```bash
shared/scripts/staging-lifecycle.sh status
shared/scripts/staging-lifecycle.sh stop --dry-run
shared/scripts/staging-lifecycle.sh stop
shared/scripts/staging-lifecycle.sh start --dry-run
shared/scripts/staging-lifecycle.sh start
```

The wrapper supports staging only. It resolves the instance from the staging
CloudFormation stack and validates its account, Region, network, recovery key,
instance profile and role, tags, inventory, and Elastic IP association. It
accepts no instance, inventory, overlay, or production overrides. A dry run
validates AWS metadata without changing resources or connecting to the host.

Stopping first acquires the host deployment lock and stops `morrowpal.service`,
which shuts down the containers cleanly. The wrapper verifies that no project
containers remain running, revalidates the target, requests a normal EC2 stop,
and waits for the stopped state. It leaves the instance, retained storage, and
Elastic IP allocated. Staging is unavailable while stopped.

Starting waits for EC2 and SSH, then waits for automatic systemd startup and
service readiness. It does not deploy configuration, build images, or repair
a failed service. Startup requires access to Secrets Manager and ECR. Allow
several minutes for recovery. An already running instance is checked for
readiness; stopping an already stopped instance makes no changes.

Status prints the validated EC2 state. When the instance is running, it also
prints container status and checks API readiness. During an EC2 transition,
wait and retry a start or stop command. Avoid concurrent deployments and
lifecycle operations; the local lifecycle lock covers commands on one machine.

After startup, check the public endpoints:

```bash
curl --fail --silent --show-error https://api.staging.morrowpal.com/ready
curl --fail --silent --show-error https://app.staging.morrowpal.com/ready
curl --fail --silent --show-error https://staging.morrowpal.com/ready
```

For a full read-only configuration preview and shared readiness checks:

```bash
shared/scripts/deploy-images.sh staging infrastructure --check
```

## Nightly shutdown

EventBridge Scheduler requests a normal EC2 stop every night at **1:00 AM
America/Chicago**, including weekends. The timezone follows daylight saving
time; the repeated hour in autumn runs once. Invocation occurs within the
scheduled minute, and shutdown takes additional time. Failed requests can
retry for up to five minutes.

The operating system stops `morrowpal.service` during shutdown, which stops the
containers. This schedule is unconditional: finish testing and deployments
before 1 AM. It does not acquire the deployment lock used by the manual lifecycle
wrapper. Start staging when needed with `shared/scripts/staging-lifecycle.sh start`.
Storage, secrets, images, and the Elastic IP remain allocated and billable.

The `morrowpal-staging-auto-stop` CloudFormation stack owns the schedule, its
dedicated group, and its execution role. The role can only stop the validated
staging instance, and only while its `Environment=staging` and
`Application=morrowpal` tags match. Its trust is restricted to the account and
schedule group. Production is rejected by both the wrapper and template.

Create a reviewed change set with:

```bash
shared/scripts/morrowpal-infrastructure-change-set.sh staging auto-stop REVIEW_NAME --dry-run
shared/scripts/morrowpal-infrastructure-change-set.sh staging auto-stop REVIEW_NAME
```

Review and execute the change set explicitly. After replacing the staging host,
update this stack through the wrapper so its target and permissions follow the
new validated instance. Change the nightly time in `shared/cloudformation/auto-stop.yml`
and review another change set to adjust the schedule.

## IAM identity tags

The shared EC2 access template manages the role's `Environment` and `Application`
tags. CloudFormation's instance-profile resource has no `Tags` property; the
profile's corresponding tags are applied separately through IAM after initial
stack creation. Routine updates preserve that profile and its tags.

For a newly created staging access stack, validate its account and role binding
before tagging the profile:

```bash
(
test "$(aws sts get-caller-identity --query Account --output text)" = 384078510608 || exit 1
access_stack=$(aws cloudformation describe-stacks \
  --stack-name morrowpal-staging-ec2-access --region us-east-1 --output json) || exit 1
profile_name=$(jq -er '.Stacks[0].Outputs[] | select(.OutputKey == "InstanceProfileName") | .OutputValue' <<<"$access_stack") || exit 1
role_arn=$(jq -er '.Stacks[0].Outputs[] | select(.OutputKey == "RoleArn") | .OutputValue' <<<"$access_stack") || exit 1
profile=$(aws iam get-instance-profile --instance-profile-name "$profile_name" --output json) || exit 1
jq -e --arg role "$role_arn" '
  (.InstanceProfile.InstanceProfileName | startswith("morrowpal-staging-ec2-access-"))
  and (.InstanceProfile.Arn | startswith("arn:aws:iam::384078510608:instance-profile/morrowpal-staging-ec2-access-"))
  and ($role | startswith("arn:aws:iam::384078510608:role/morrowpal-staging-ec2-access-"))
  and [.InstanceProfile.Roles[].Arn] == [$role]
' <<<"$profile" >/dev/null || exit 1
aws iam tag-instance-profile --instance-profile-name "$profile_name" \
  --tags Key=Environment,Value=staging Key=Application,Value=morrowpal
)
```

These tags identify staging resources; they do not change role membership or
policy documents. The separate IAM tagging step must be repeated if the access
stack creates a replacement profile.

## Stack and network identity tags

The guarded CloudFormation change-set wrapper applies `Environment` and
`Application` stack tags for the selected environment and preserves other
existing stack tags. Staging tag backfills reuse the deployed templates and
current parameter values; each change set is reviewed before execution.

The primary network interface is created inside the EC2 instance definition,
whose embedded network-interface properties have no `Tags` field. Its common
tags are applied in place. After host replacement, validate and tag the new
primary interface:

```bash
(
test "$(aws sts get-caller-identity --query Account --output text)" = 384078510608 || exit 1
instance_id=$(aws cloudformation describe-stacks --stack-name morrowpal-staging-ec2 \
  --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue | [0]' --output text) || exit 1
host=$(aws ec2 describe-instances --instance-ids "$instance_id" --region us-east-1 --output json) || exit 1
jq -e '.Reservations[0].OwnerId=="384078510608" and (.Reservations[0].Instances[0] |
  any(.Tags[]; .Key=="Environment" and .Value=="staging")
  and any(.Tags[]; .Key=="Application" and .Value=="morrowpal")
  and any(.Tags[]; .Key=="aws:cloudformation:stack-name" and .Value=="morrowpal-staging-ec2"))' <<<"$host" >/dev/null || exit 1
interface_id=$(jq -er '.Reservations[0].Instances[0].NetworkInterfaces[] |
  select(.Attachment.DeviceIndex==0) | .NetworkInterfaceId' <<<"$host") || exit 1
aws ec2 create-tags --resources "$interface_id" --region us-east-1 \
  --tags Key=Environment,Value=staging Key=Application,Value=morrowpal
)
```

This changes tag metadata without detaching the interface or changing its
addresses or security groups.

## Billing cost filters

The shared account has `Environment` and `Application` activated as cost
allocation tag keys. In Cost Explorer, select `Environment=staging` and,
when needed, `Application=morrowpal` to see staging-attributed costs. Shared
or untagged charges may remain outside that filter. Activation and reporting
data can take time to become available.

Check activation status with:

```bash
aws ce list-cost-allocation-tags --tag-keys Environment Application --region us-east-1
```

Activation applies to every value of the keys in this account. It does not
tag or restart production resources. The lowercase keys are separate and remain
inactive.

## Monthly budget alerts

The staging monthly budget is USD 15. Email notifications warn when actual
staging-tagged costs exceed 80% or 100% of that amount (USD 12 and USD 15).
Credits, refunds, and taxes are excluded. This budget monitors spending and
sends email; it does not impose a spending cap or stop resources. Alert timing
depends on AWS billing data updates.

The shared budget template takes the amount and recipient as inputs. To prepare
a reviewed update, supply the intended recipient:

```bash
MORROWPAL_MONTHLY_BUDGET_USD=15 \
MORROWPAL_BUDGET_ALERT_EMAIL='you@example.com' \
shared/scripts/morrowpal-infrastructure-change-set.sh staging budget staging-budget-review
```

Review the change set before execution. The budget filter is
`Environment=staging`; untagged or shared costs outside that filter are excluded.
The budget can be managed while staging is stopped.

Read its configuration with:

```bash
aws budgets describe-budget --account-id 384078510608 \
  --budget-name morrowpal-staging-budget-monthly --region us-east-1
```
