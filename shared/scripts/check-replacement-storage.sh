#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: check-replacement-storage.sh ENVIRONMENT RECORD.json original|candidate|detached\nRead-only AWS storage checks; not a complete cutover preflight.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 3 ]] || { usage >&2; exit 2; }
environment="$1" attachment="$3"
case "$environment" in staging|prod) ;; *) fail 'Environment must be staging or prod' ;; esac
case "$attachment" in original|candidate|detached) ;; *) fail 'Expected attachment must be original, candidate or detached' ;; esac
for tool in aws jq ansible; do command -v "$tool" >/dev/null || fail "Required command not found: $tool"; done
umask 077
work_directory="$(mktemp -d)"
trap 'rm -rf -- "$work_directory"' EXIT
cp -- "$2" "$work_directory/record.json"
record="$work_directory/record.json"
bash "$script_directory/validate-replacement-record.sh" "$environment" "$record" >/dev/null
account="$(jq -r .accountId "$record")"
region="$(jq -r .region "$record")"
volume="$(jq -r .data.volumeId "$record")"
snapshot="$(jq -r .data.snapshotId "$record")"
stack="morrowpal-$environment-mysql-storage"
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$region" ]] || fail "$variable does not match the record Region"
done
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] \
    || fail 'AWS account does not match the replacement record'
aws cloudformation describe-stacks --stack-name "$stack" --region "$region" --output json >"$work_directory/stack.json"
jq -e --slurpfile record "$record" --arg attachment "$attachment" \
    --arg arn "arn:aws:cloudformation:$region:$account:stack/$stack/" '
    def output($key): [.Outputs[]? | select(.OutputKey == $key) | .OutputValue];
    def parameter($key): [.Parameters[]? | select(.ParameterKey == $key) | .ParameterValue];
    $record[0] as $r | (.Stacks | length) == 1 and (.Stacks[0] |
        (.StackId | startswith($arn))
        and (.StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"))
        and output("VolumeId") == [$r.data.volumeId] and output("DeviceName") == ["/dev/sdf"]
        and parameter("AvailabilityZone") == [$r.availabilityZone]
        and (if $attachment == "detached" then
            parameter("AttachVolume") == ["false"]
            and (parameter("InstanceId") == [$r.original.instanceId] or parameter("InstanceId") == [$r.candidate.instanceId])
        else parameter("AttachVolume") == ["true"] and parameter("InstanceId") == [$r[$attachment].instanceId] end))
' "$work_directory/stack.json" >/dev/null || fail 'Storage stack identity, outputs or attachment parameters mismatch'
stack_id="$(jq -r .Stacks[0].StackId "$work_directory/stack.json")"
aws ec2 describe-volumes --volume-ids "$volume" --region "$region" --output json >"$work_directory/volume.json"
jq -e --slurpfile record "$record" --arg stack "$stack" --arg stackId "$stack_id" --arg attachment "$attachment" '
    $record[0] as $r | (.Volumes | length) == 1 and (.Volumes[0] |
        .VolumeId == $r.data.volumeId and .AvailabilityZone == $r.availabilityZone
        and .Encrypted == true and .VolumeType == "gp3" and .MultiAttachEnabled == false
        and (.KmsKeyId | type == "string" and length > 0)
        and (.Size | type == "number" and . >= 1 and floor == .)
        and ([.Tags[]? | select(.Key == "Environment") | .Value] == [$r.environment])
        and ([.Tags[]? | select(.Key == "Application") | .Value] == ["morrowpal"])
        and ([.Tags[]? | select(.Key == "aws:cloudformation:stack-name") | .Value] == [$stack])
        and ([.Tags[]? | select(.Key == "aws:cloudformation:stack-id") | .Value] == [$stackId])
        and (if $attachment == "detached" then .State == "available" and .Attachments == []
        else .State == "in-use" and (.Attachments | length) == 1 and (.Attachments[0] |
            .InstanceId == $r[$attachment].instanceId and .VolumeId == $r.data.volumeId
            and .Device == "/dev/sdf" and .State == "attached" and .DeleteOnTermination == false) end))
' "$work_directory/volume.json" >/dev/null || fail 'Retained data volume identity, encryption or attachment mismatch'
aws ec2 describe-snapshots --snapshot-ids "$snapshot" --owner-ids self --region "$region" \
    --output json >"$work_directory/snapshot.json"
jq -e --slurpfile record "$record" --slurpfile volume "$work_directory/volume.json" '
    $record[0] as $r | $volume[0].Volumes[0] as $v |
    (.Snapshots | length) == 1 and (.Snapshots[0] |
        .SnapshotId == $r.data.snapshotId and .OwnerId == $r.accountId and .VolumeId == $r.data.volumeId
        and .State == "completed" and .Encrypted == true and .StorageTier == "standard"
        and .VolumeSize == $v.Size and .KmsKeyId == $v.KmsKeyId
        and ([.Tags[]? | select(.Key == "Environment") | .Value] == [$r.environment])
        and ([.Tags[]? | select(.Key == "Application") | .Value] == ["morrowpal"]))
' "$work_directory/snapshot.json" >/dev/null || fail 'Recovery snapshot ownership, source, completion or encryption mismatch'
printf '%s retained storage and snapshot metadata checked against AWS; expected attachment: %s. Filesystem UUID, quiescence, snapshot freshness/restore and other cutover checks remain required.\n' "$environment" "$attachment"
