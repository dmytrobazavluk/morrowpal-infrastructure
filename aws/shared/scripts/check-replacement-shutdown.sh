#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: check-replacement-shutdown.sh staging RECORD.json original|candidate ENABLED|DISABLED\nRead-only schedule and least-privilege role checks.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 4 ]] || { usage >&2; exit 2; }
[[ "$1" == staging ]] || fail 'Shutdown recovery checks support staging only'
host="$3" state="$4"
case "$host" in original|candidate) ;; *) fail 'Expected target must be original or candidate' ;; esac
case "$state" in ENABLED|DISABLED) ;; *) fail 'Expected schedule state must be ENABLED or DISABLED' ;; esac
for tool in aws jq ansible; do command -v "$tool" >/dev/null || fail "Required command not found: $tool"; done
umask 077
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cp -- "$2" "$work/record.json"
record="$work/record.json"
bash "$script_directory/validate-replacement-record.sh" staging "$record" >/dev/null
account="$(jq -r .accountId "$record")" region="$(jq -r .region "$record")"
instance="$(jq -r --arg host "$host" '.[$host].instanceId' "$record")"
group="$(jq -r .shutdown.groupName "$record")" name="$(jq -r .shutdown.scheduleName "$record")"
group_arn="arn:aws:scheduler:$region:$account:schedule-group/$group"
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$region" ]] || fail "$variable does not match the record Region"
done
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] || fail 'AWS account mismatch'
aws cloudformation describe-stacks --stack-name morrowpal-staging-auto-stop --region "$region" --output json >"$work/stack.json"
jq -e --arg arn "arn:aws:cloudformation:$region:$account:stack/morrowpal-staging-auto-stop/" \
    --arg instance "$instance" --arg state "$state" --arg group "$group" --arg name "$name" '
    def output($k): [.Outputs[]? | select(.OutputKey == $k) | .OutputValue];
    (.Stacks | length) == 1 and (.Stacks[0] | (.StackId | startswith($arn))
      and (.StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"))
      and [.Parameters[]? | select(.ParameterKey == "InstanceId") | .ParameterValue] == [$instance]
      and ([.Parameters[]? | select(.ParameterKey == "ScheduleState") | .ParameterValue] as $states |
        $states == [$state] or ($state == "ENABLED" and $states == []))
      and output("ScheduleGroupName") == [$group] and output("ScheduleName") == [$name]
      and (output("ExecutionRoleArn") | length == 1))
' "$work/stack.json" >/dev/null || fail 'Shutdown stack identity, outputs or target/state mismatch'
role_arn="$(jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ExecutionRoleArn") | .OutputValue' "$work/stack.json")"
[[ "$role_arn" == "arn:aws:iam::$account:role/"* ]] || fail 'Shutdown role account mismatch'
role="${role_arn##*/}"
aws scheduler get-schedule --group-name "$group" --name "$name" --region "$region" --output json >"$work/schedule.json"
jq -e --arg arn "arn:aws:scheduler:$region:$account:schedule/$group/$name" --arg state "$state" \
    --arg group "$group" --arg name "$name" --arg instance "$instance" --arg role "$role_arn" '
    .Arn == $arn and .GroupName == $group and .Name == $name and .State == $state
    and .ScheduleExpression == "cron(0 1 * * ? *)" and .ScheduleExpressionTimezone == "America/Chicago"
    and .FlexibleTimeWindow == {Mode:"OFF"} and (.ActionAfterCompletion // "NONE") == "NONE"
    and .StartDate == null and .EndDate == null
    and .Target.Arn == "arn:aws:scheduler:::aws-sdk:ec2:stopInstances" and .Target.RoleArn == $role
    and (.Target.Input | fromjson) == {InstanceIds:[$instance],Force:false}
    and .Target.RetryPolicy == {MaximumEventAgeInSeconds:300,MaximumRetryAttempts:2}
' "$work/schedule.json" >/dev/null || fail 'Nightly shutdown schedule binding mismatch'
aws iam get-role --role-name "$role" --region "$region" --output json >"$work/role.json"
jq -e --arg role "$role_arn" --arg account "$account" --arg group "$group_arn" '
    def array: if type == "array" then . else [.] end;
    .Role.Arn == $role and (.Role.AssumeRolePolicyDocument |
      .Version == "2012-10-17" and (.Statement | length) == 1 and (.Statement[0] |
        .Effect == "Allow" and (.Action | array) == ["sts:AssumeRole"]
        and .Principal == {Service:"scheduler.amazonaws.com"}
        and .Condition == {StringEquals:{"aws:SourceAccount":$account},ArnEquals:{"aws:SourceArn":$group}}))
' "$work/role.json" >/dev/null || fail 'Shutdown role trust mismatch'
aws iam list-role-policies --role-name "$role" --region "$region" --output json >"$work/inline.json"
aws iam list-attached-role-policies --role-name "$role" --region "$region" --output json >"$work/attached.json"
jq -e '.PolicyNames == ["StopStagingInstance"]' "$work/inline.json" >/dev/null || fail 'Unexpected shutdown inline policies'
jq -e '.AttachedPolicies == []' "$work/attached.json" >/dev/null || fail 'Unexpected shutdown managed policies'
aws iam get-role-policy --role-name "$role" --policy-name StopStagingInstance --region "$region" --output json >"$work/policy.json"
jq -e --arg arn "arn:aws:ec2:$region:$account:instance/$instance" '
    def array: if type == "array" then . else [.] end;
    .PolicyDocument | .Version == "2012-10-17" and (.Statement | length) == 1 and (.Statement[0] |
      .Effect == "Allow" and (.Action | array) == ["ec2:StopInstances"] and (.Resource | array) == [$arn]
      and .NotAction == null and .NotResource == null
      and .Condition == {StringEquals:{"ec2:ResourceTag/Environment":"staging","ec2:ResourceTag/Application":"morrowpal"}})
' "$work/policy.json" >/dev/null || fail 'Shutdown role permission scope mismatch'
printf 'Staging nightly shutdown targets %s with state %s and an exact instance/tag-scoped role.\n' "$host" "$state"
