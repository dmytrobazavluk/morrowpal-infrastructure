#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Usage: execute-staging-replacement-change-set.sh candidate|detach|attach|public-ip|auto-stop STACK CHANGE_SET'
operation="$1" stack="$2" change_set="$3"
case "$operation:$stack" in
    candidate:morrowpal-staging-ec2-*) [[ "$stack" =~ ^morrowpal-staging-ec2-[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] || fail 'Invalid candidate stack' ;;
    detach:morrowpal-staging-mysql-storage|attach:morrowpal-staging-mysql-storage|public-ip:morrowpal-staging-public-ip|auto-stop:morrowpal-staging-auto-stop) ;;
    *) fail 'Operation/stack must be an approved staging replacement pair' ;;
esac
[[ "$change_set" =~ ^[A-Za-z][-A-Za-z0-9]*$ ]] || fail 'Invalid change-set name'
umask 077
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
ANSIBLE_CONFIG="$repository/ansible.cfg" ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
    ansible localhost -i localhost, --connection local -m ansible.builtin.template \
    --args "src=$repository/shared/runtime/cloudformation.env.j2 dest=$work/env mode=0600" \
    -e "@$repository/environments/staging/vars.yml" >/dev/null
source "$work/env"
[[ "$MORROWPAL_ENVIRONMENT" == staging && "$MORROWPAL_STACK_PREFIX" == morrowpal-staging ]] || fail 'Not staging configuration'
region="$MORROWPAL_AWS_REGION" account="$MORROWPAL_AWS_ACCOUNT_ID"
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$region" ]] || fail 'Region override mismatch'
done
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] || fail 'AWS account mismatch'
aws cloudformation wait change-set-create-complete --stack-name "$stack" --change-set-name "$change_set" --region "$region" || true
aws cloudformation describe-change-set --stack-name "$stack" --change-set-name "$change_set" --region "$region" --output json >"$work/change-set.json"
jq -e --arg prefix "arn:aws:cloudformation:$region:$account:stack/$stack/" --arg name "$change_set" '
    (.StackId | startswith($prefix)) and .ChangeSetName == $name
    and [.Parameters[]? | select(.ParameterKey == "Environment") | .ParameterValue] == ["staging"]
' "$work/change-set.json" >/dev/null || fail 'Change-set identity or environment mismatch'
if jq -e '.Status == "FAILED" and (.Changes | length) == 0
    and (.StatusReason | contains("didn\u0027t contain changes"))' "$work/change-set.json" >/dev/null; then
    [[ "$operation" != candidate ]] || fail 'Candidate creation cannot be empty'
    printf 'No resource changes for %s; caller must verify the desired state.\n' "$stack"
    exit 0
fi
jq -e --arg operation "$operation" '
    .Status == "CREATE_COMPLETE" and .ExecutionStatus == "AVAILABLE" and (.Changes | length) > 0
    and all(.Changes[]; .Type == "Resource" and (.ResourceChange |
      if $operation == "candidate" then .Action == "Add" and .LogicalResourceId == "ProductionInstance" and .ResourceType == "AWS::EC2::Instance"
      elif $operation == "detach" then .Action == "Remove" and .LogicalResourceId == "MysqlDataVolumeAttachment" and .ResourceType == "AWS::EC2::VolumeAttachment"
      elif $operation == "attach" then .Action == "Add" and .LogicalResourceId == "MysqlDataVolumeAttachment" and .ResourceType == "AWS::EC2::VolumeAttachment"
      elif $operation == "public-ip" then .Action == "Modify" and .LogicalResourceId == "ProductionElasticIpAssociation" and .ResourceType == "AWS::EC2::EIPAssociation"
      else .Action == "Modify" and .Replacement == "False" and
        ((.LogicalResourceId == "NightlyStop" and .ResourceType == "AWS::Scheduler::Schedule") or
         (.LogicalResourceId == "ExecutionRole" and .ResourceType == "AWS::IAM::Role")) end))
' "$work/change-set.json" >/dev/null || fail 'Change set includes an unexpected action, resource, or replacement'
jq -c '{StackId,ChangeSetName,Changes:[.Changes[].ResourceChange|{Action,LogicalResourceId,ResourceType,Replacement}]}' "$work/change-set.json"
# The description above is checked before every execution; no data volume/EIP/old EC2 can be replaced here.
aws cloudformation execute-change-set --stack-name "$stack" --change-set-name "$change_set" --region "$region"
waiter=stack-update-complete
[[ "$operation" != candidate ]] || waiter=stack-create-complete
aws cloudformation wait "$waiter" --stack-name "$stack" --region "$region"
printf 'Completed staging replacement change: %s / %s.\n' "$operation" "$stack"
