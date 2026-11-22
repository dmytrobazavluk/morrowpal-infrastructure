#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: check-replacement-ip.sh ENVIRONMENT RECORD.json original|candidate\nRead-only AWS Elastic IP checks; not a complete cutover preflight.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 3 ]] || { usage >&2; exit 2; }
environment="$1" attachment="$3"
case "$environment" in staging|prod) ;; *) fail 'Environment must be staging or prod' ;; esac
case "$attachment" in original|candidate) ;; *) fail 'Expected attachment must be original or candidate' ;; esac
for tool in aws jq ansible; do command -v "$tool" >/dev/null || fail "Required command not found: $tool"; done
umask 077
work_directory="$(mktemp -d)"
trap 'rm -rf -- "$work_directory"' EXIT
cp -- "$2" "$work_directory/record.json"
record="$work_directory/record.json"
bash "$script_directory/validate-replacement-record.sh" "$environment" "$record" >/dev/null
account="$(jq -r .accountId "$record")"
region="$(jq -r .region "$record")"
allocation="$(jq -r .publicIp.allocationId "$record")"
stack="morrowpal-$environment-public-ip"
host_stack="$(jq -r --arg host "$attachment" '.[$host].stackName' "$record")"
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
    ' "$destination" >/dev/null || fail 'Public IP or target host stack identity/state mismatch'
}
read_stack "$stack" "$work_directory/stack.json"
jq -e --slurpfile record "$record" --arg host "$attachment" '
    def output($key): [.Outputs[]? | select(.OutputKey == $key) | .OutputValue];
    $record[0] as $r | .Stacks[0] |
    output("AllocationId") == [$r.publicIp.allocationId] and output("PublicIp") == [$r.publicIp.address]
    and [.Parameters[]? | select(.ParameterKey == "InstanceId") | .ParameterValue] == [$r[$host].instanceId]
' "$work_directory/stack.json" >/dev/null || fail 'Public IP stack outputs or target parameter mismatch'
stack_id="$(jq -r .Stacks[0].StackId "$work_directory/stack.json")"
read_stack "$host_stack" "$work_directory/host-stack.json"
jq -e --slurpfile record "$record" --arg host "$attachment" '
    $record[0] as $r | .Stacks[0] |
    [.Outputs[]? | select(.OutputKey == "InstanceId") | .OutputValue] == [$r[$host].instanceId]
    and [.Outputs[]? | select(.OutputKey == "AvailabilityZone") | .OutputValue] == [$r.availabilityZone]
' "$work_directory/host-stack.json" >/dev/null || fail 'Target host stack outputs mismatch'
aws ec2 describe-addresses --allocation-ids "$allocation" --region "$region" --output json >"$work_directory/address.json"
jq -e --slurpfile record "$record" --arg host "$attachment" --arg stack "$stack" --arg stackId "$stack_id" '
    def id($prefix): type == "string" and test("^" + $prefix + "-([0-9a-f]{8}|[0-9a-f]{17})$");
    $record[0] as $r | (.Addresses | length) == 1 and (.Addresses[0] |
        .AllocationId == $r.publicIp.allocationId and .PublicIp == $r.publicIp.address and .Domain == "vpc"
        and .InstanceId == $r[$host].instanceId and .NetworkInterfaceOwnerId == $r.accountId
        and (.AssociationId | id("eipassoc")) and (.NetworkInterfaceId | id("eni"))
        and (.PrivateIpAddress | type == "string" and length > 0)
        and ([.Tags[]? | select(.Key == "Environment") | .Value] == [$r.environment])
        and ([.Tags[]? | select(.Key == "Application") | .Value] == ["morrowpal"])
        and ([.Tags[]? | select(.Key == "aws:cloudformation:stack-name") | .Value] == [$stack])
        and ([.Tags[]? | select(.Key == "aws:cloudformation:stack-id") | .Value] == [$stackId]))
' "$work_directory/address.json" >/dev/null || fail 'Retained Elastic IP identity, tags or association mismatch'
interface="$(jq -r .Addresses[0].NetworkInterfaceId "$work_directory/address.json")"
aws ec2 describe-network-interfaces --network-interface-ids "$interface" --region "$region" \
    --output json >"$work_directory/interface.json"
jq -e --slurpfile record "$record" --slurpfile address "$work_directory/address.json" --arg host "$attachment" '
    $record[0] as $r | $address[0].Addresses[0] as $a |
    (.NetworkInterfaces | length) == 1 and (.NetworkInterfaces[0] |
        .NetworkInterfaceId == $a.NetworkInterfaceId and .OwnerId == $r.accountId
        and .VpcId == $r.network.vpcId and .SubnetId == $r.network.subnetId
        and .AvailabilityZone == $r.availabilityZone and [.Groups[].GroupId] == [$r.network.securityGroupId]
        and .Status == "in-use" and .Attachment.Status == "attached"
        and .Attachment.InstanceId == $r[$host].instanceId and .Attachment.DeviceIndex == 0
        and .PrivateIpAddress == $a.PrivateIpAddress
        and .Association.AllocationId == $a.AllocationId and .Association.AssociationId == $a.AssociationId
        and .Association.PublicIp == $a.PublicIp
        and ([.PrivateIpAddresses[]? | select(.Primary == true) | .PrivateIpAddress] == [$a.PrivateIpAddress]))
' "$work_directory/interface.json" >/dev/null || fail 'Elastic IP primary interface, network or association mismatch'
printf '%s retained Elastic IP metadata checked against AWS; expected attachment: %s. DNS, host identity/readiness and other cutover checks remain required.\n' "$environment" "$attachment"
