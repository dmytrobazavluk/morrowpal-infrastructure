#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: check-replacement-hosts.sh ENVIRONMENT RECORD.json\nRead-only AWS host checks; not a complete cutover preflight.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
environment="$1"
case "$environment" in staging|prod) ;; *) fail 'Environment must be staging or prod' ;; esac
for tool in aws jq ansible; do command -v "$tool" >/dev/null || fail "Required command not found: $tool"; done
umask 077
work_directory="$(mktemp -d)"
trap 'rm -rf -- "$work_directory"' EXIT
# Freeze the input for this read-only pass. No script below updates the record.
cp -- "$2" "$work_directory/record.json"
record="$work_directory/record.json"
bash "$script_directory/validate-replacement-record.sh" "$environment" "$record" >/dev/null
account="$(jq -r .accountId "$record")"
region="$(jq -r .region "$record")"
zone="$(jq -r .availabilityZone "$record")"
prefix="morrowpal-$environment"
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$region" ]] || fail "$variable does not match the record Region"
done
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] \
    || fail 'AWS account does not match the replacement record'
read_stack() {
    local name="$1" destination="$2"
    aws cloudformation describe-stacks --stack-name "$name" --region "$region" --output json >"$destination"
    jq -e --arg arn "arn:aws:cloudformation:$region:$account:stack/$name/" '
        (.Stacks | length) == 1 and (.Stacks[0].StackId | startswith($arn))
        and (.Stacks[0].StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"))
    ' "$destination" >/dev/null || fail 'Replacement stack identity or state mismatch'
}
output() {
    jq -er --arg key "$2" '[.Stacks[0].Outputs[]? | select(.OutputKey == $key) | .OutputValue]
        | select(length == 1) | .[0] | select(type == "string" and length > 0)' "$1"
}
read_stack "$prefix-ec2-access" "$work_directory/access.json"
profile="$(output "$work_directory/access.json" InstanceProfileArn)"
role="$(output "$work_directory/access.json" RoleArn)"
[[ "$profile" == "arn:aws:iam::$account:instance-profile/"* && "$role" == "arn:aws:iam::$account:role/"* ]] \
    || fail 'Access stack account mismatch'
aws iam get-instance-profile --instance-profile-name "${profile##*/}" --region "$region" \
    --output json >"$work_directory/profile.json"
jq -e --arg profile "$profile" --arg role "$role" '
    .InstanceProfile.Arn == $profile and [.InstanceProfile.Roles[].Arn] == [$role]
' "$work_directory/profile.json" >/dev/null || fail 'Access stack role/profile mismatch'

for host in original candidate; do
    stack="$(jq -r --arg host "$host" '.[$host].stackName' "$record")"
    instance="$(jq -r --arg host "$host" '.[$host].instanceId' "$record")"
    root="$(jq -r --arg host "$host" '.[$host].rootVolumeId' "$record")"
    read_stack "$stack" "$work_directory/stack.json"
    [[ "$(output "$work_directory/stack.json" InstanceId)" == "$instance" && \
        "$(output "$work_directory/stack.json" AvailabilityZone)" == "$zone" ]] \
        || fail "$host stack output mismatch"
    stack_id="$(jq -r .Stacks[0].StackId "$work_directory/stack.json")"
    aws ec2 describe-instances --instance-ids "$instance" --region "$region" \
        --output json >"$work_directory/instance.json"
    jq -e --slurpfile record "$record" --arg host "$host" --arg profile "$profile" --arg stackId "$stack_id" '
        $record[0] as $r | $r[$host] as $h |
        (.Reservations | length) == 1 and .Reservations[0].OwnerId == $r.accountId
        and (.Reservations[0].Instances | length) == 1
        and (.Reservations[0].Instances[0] |
            .InstanceId == $h.instanceId and .ImageId == $h.amiId
            and .VpcId == $r.network.vpcId and .SubnetId == $r.network.subnetId
            and [.SecurityGroups[].GroupId] == [$r.network.securityGroupId]
            and .Placement.AvailabilityZone == $r.availabilityZone and .KeyName == $r.network.keyName
            and .IamInstanceProfile.Arn == $profile and (.State.Name | IN("running","stopped"))
            and ([.Tags[]? | select(.Key == "Environment") | .Value] == [$r.environment])
            and ([.Tags[]? | select(.Key == "Application") | .Value] == ["morrowpal"])
            and ([.Tags[]? | select(.Key == "Name") | .Value] == ["morrowpal-" + $r.environment + "-01"])
            and ([.Tags[]? | select(.Key == "aws:cloudformation:stack-name") | .Value] == [$h.stackName])
            and ([.Tags[]? | select(.Key == "aws:cloudformation:stack-id") | .Value] == [$stackId])
            and .RootDeviceType == "ebs" and (.RootDeviceName | type == "string" and length > 0)
            and (.RootDeviceName as $device |
                [.BlockDeviceMappings[]? | select(.DeviceName == $device) | .Ebs]
                | length == 1 and .[0].VolumeId == $h.rootVolumeId and .[0].Status == "attached"))
    ' "$work_directory/instance.json" >/dev/null || fail "$host instance identity, state or root mapping mismatch"
    device="$(jq -r .Reservations[0].Instances[0].RootDeviceName "$work_directory/instance.json")"
    aws ec2 describe-volumes --volume-ids "$root" --region "$region" --output json >"$work_directory/root.json"
    jq -e --arg root "$root" --arg instance "$instance" --arg zone "$zone" --arg device "$device" '
        (.Volumes | length) == 1 and (.Volumes[0] |
            .VolumeId == $root and .AvailabilityZone == $zone and .Encrypted == true
            and .VolumeType == "gp3" and .State == "in-use"
            and (.Attachments | length) == 1 and (.Attachments[0] |
                .InstanceId == $instance and .VolumeId == $root and .Device == $device and .State == "attached"))
    ' "$work_directory/root.json" >/dev/null || fail "$host root volume mismatch"
done
ami="$(jq -r .candidate.amiId "$record")"
aws ec2 describe-images --image-ids "$ami" --include-deprecated --region "$region" \
    --output json >"$work_directory/image.json"
jq -e --arg ami "$ami" --slurpfile policy "$repository_directory/shared/ec2-image.json" '
    (.Images | length) == 1 and (.Images[0] | .ImageId == $ami and .Name == $policy[0].name
        and .OwnerId == $policy[0].ownerId and .Architecture == $policy[0].architecture
        and .RootDeviceType == "ebs" and .VirtualizationType == "hvm" and .State == "available"
        and .ImageAllowed != false)
' "$work_directory/image.json" >/dev/null || fail 'Candidate AMI does not match shared image policy'
printf '%s replacement host identities checked against AWS. Data, IP, snapshot, releases, scheduler and filesystem checks remain required before cutover.\n' "$environment"
