#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'Usage: trust-staging-host-via-ssm.sh RECORD.json original|candidate'
record_path="$(realpath -- "$1")" target="$2"
case "$target" in original|candidate) ;; *) fail 'Invalid target' ;; esac
umask 077
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cp "$record_path" "$work/record.json"
record="$work/record.json"
cd "$repository"
bash "$directory/validate-replacement-record.sh" staging "$record"
bash "$directory/check-replacement-hosts.sh" staging "$record"
bash "$directory/check-replacement-ip.sh" staging "$record" "$target"
region="$(jq -r .region "$record")" instance="$(jq -r --arg target "$target" '.[$target].instanceId' "$record")" ip="$(jq -r .publicIp.address "$record")"
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$instance" --region "$region" --output json >"$work/node.json"
jq -e --arg instance "$instance" '[.InstanceInformationList[] | select(.InstanceId == $instance and .PingStatus == "Online")] | length == 1' "$work/node.json" >/dev/null || fail 'Selected staging host is not online in Systems Manager'
# This command is fixed and reads public host keys only; no private keys or application secrets.
command_id="$(aws ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript \
    --parameters 'commands=["cat /etc/ssh/ssh_host_ed25519_key.pub"]' --region "$region" --query Command.CommandId --output text)"
[[ "$command_id" =~ ^[0-9a-f-]{36}$ ]] || fail 'Invalid SSM command ID'
aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance" --region "$region"
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" --region "$region" \
    --query '{InstanceId:InstanceId,Status:Status,PublicHostKeys:StandardOutputContent}' --output json >"$work/result.json"
jq -e --arg instance "$instance" '.InstanceId == $instance and .Status == "Success" and (.PublicHostKeys | type == "string")' "$work/result.json" >/dev/null || fail 'Unverified SSM response'
jq -r .PublicHostKeys "$work/result.json" | awk '$1 == "ssh-ed25519" && $2 ~ /^[A-Za-z0-9+\/=]+$/ { print $1 " " $2 }' | LC_ALL=C sort -u >"$work/trusted"
[[ -s "$work/trusted" ]] || fail 'No public host key returned'
ssh-keyscan -T 10 -t ed25519 "$ip" >"$work/scanned" 2>/dev/null
awk '$2 == "ssh-ed25519" { print $2 " " $3 }' "$work/scanned" | LC_ALL=C sort -u >"$work/observed"
LC_ALL=C comm -12 "$work/trusted" "$work/observed" >"$work/matching"
[[ -s "$work/matching" ]] || fail 'SSH scan does not match authenticated SSM public key'
awk -v ip="$ip" '{ print ip " " $0 }' "$work/matching" >"$record_path.known-hosts.$target"
jq --arg command "$command_id" '. + {CommandId:$command}' "$work/result.json" >"$record_path.ssm-host-keys.$target.json"
printf 'Staging %s SSH public host key verified through authenticated SSM and matched against the network endpoint.\n' "$target"
