# Staging operations

Run commands from `infrastructure` with AWS credentials for the account and
Region configured in `environments/staging/vars.yml`.

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
containers remain runniNsT3fOU1*Ef%gPqong, revalidates the target, requests a normal EC2 stop,
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
