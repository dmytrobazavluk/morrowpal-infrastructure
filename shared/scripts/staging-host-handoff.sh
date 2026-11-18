#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]##*/}" == staging-host-handoff.sh ]]; then
    # Bash reads source lazily across AWS waits. Keep this run's source immutable.
    frozen="$(mktemp "$directory/.staging-handoff.XXXXXX")"
    trap 'rm -f -- "$frozen"' EXIT
    cp -- "${BASH_SOURCE[0]}" "$frozen"
    result=0
    bash "$frozen" "$@" || result=$?
    exit "$result"
fi
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: staging-host-handoff.sh RECORD.json original|candidate [--execute|--enable-shutdown]\nDefault is read-only. Handoff requires BOTH hosts stopped and leaves them stopped.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 2 || $# == 3 ]] || { usage >&2; exit 2; }
record_path="$(realpath -- "$1")" target="$2" mode="${3:---dry-run}"
case "$target" in original|candidate) ;; *) fail 'Target must be original or candidate' ;; esac
case "$mode" in --dry-run|--execute|--enable-shutdown) ;; *) fail 'Unknown execution mode' ;; esac
for tool in jq aws ansible flock sha256sum; do command -v "$tool" >/dev/null || fail "Missing command: $tool"; done
# Serialize local replacement, lifecycle and release operations. External operators must honor the maintenance window.
exec 9>/tmp/morrowpal-staging-host-handoff.lock
flock --exclusive --nonblock 9 || fail 'Another staging lifecycle, deployment or replacement command is running'
umask 077
work="$(mktemp -d)"
phase=preflight
trap 'rc=$?; rm -rf -- "$work"; if ((rc)); then printf "Stopped at phase %s. Do not start either host after a partial handoff; rerun toward either recorded target after correcting the failure.\n" "$phase" >&2; fi' EXIT
cp -- "$record_path" "$work/record.json"
record="$work/record.json"
bash "$directory/validate-replacement-record.sh" staging "$record"
account="$(jq -r .accountId "$record")" region="$(jq -r .region "$record")"
original="$(jq -r .original.instanceId "$record")" candidate="$(jq -r .candidate.instanceId "$record")"
vars="$repository/environments/staging/vars.yml"
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off
cd "$repository"
stack() { aws cloudformation describe-stacks --stack-name "morrowpal-staging-$1" --region "$region" --output json; }
parameter() { jq -er --arg key "$2" '.Stacks[0].Parameters[] | select(.ParameterKey == $key) | .ParameterValue' "$1"; }
host_for() {
    case "$1" in "$original") printf 'original\n' ;; "$candidate") printf 'candidate\n' ;; *) fail 'Cross-stack target is outside the replacement record' ;; esac
}
bindings() {
    stack mysql-storage >"$work/storage.json"
    stack public-ip >"$work/ip.json"
    stack auto-stop >"$work/shutdown.json"
    storage_host="$(host_for "$(parameter "$work/storage.json" InstanceId)")"
    case "$(parameter "$work/storage.json" AttachVolume)" in
        false) storage_host=detached ;; true) ;; *) fail 'Invalid storage attachment flag' ;;
    esac
    ip_host="$(host_for "$(parameter "$work/ip.json" InstanceId)")"
    shutdown_host="$(host_for "$(parameter "$work/shutdown.json" InstanceId)")"
    shutdown_state="$(jq -r '[.Stacks[0].Parameters[] | select(.ParameterKey == "ScheduleState") | .ParameterValue][0] // "ENABLED"' "$work/shutdown.json")"
}
instances() { aws ec2 describe-instances --instance-ids "$original" "$candidate" --region "$region" --output json >"$work/instances.json"; }
require_stopped() {
    instances
    jq -e --arg account "$account" --arg original "$original" --arg candidate "$candidate" '
      all(.Reservations[]; .OwnerId == $account)
      and ([.Reservations[].Instances[].InstanceId] | sort) == ([$original,$candidate] | sort)
      and all(.Reservations[].Instances[]; .State.Name == "stopped")
    ' "$work/instances.json" >/dev/null || fail 'Both recorded hosts must be stopped before infrastructure handoff'
}
guard() {
    local -a pids=()
    local failed=false kind pid
    bash "$directory/validate-replacement-record.sh" staging "$record" >/dev/null
    bindings
    # These reads are independent. Wait for every result before permitting a mutation.
    bash "$directory/check-replacement-hosts.sh" staging "$record" >"$work/hosts-check.log" 2>&1 & pids+=("$!")
    bash "$directory/check-replacement-storage.sh" staging "$record" "$storage_host" >"$work/storage-check.log" 2>&1 & pids+=("$!")
    bash "$directory/check-replacement-ip.sh" staging "$record" "$ip_host" >"$work/ip-check.log" 2>&1 & pids+=("$!")
    bash "$directory/check-replacement-shutdown.sh" staging "$record" "$shutdown_host" "$shutdown_state" >"$work/shutdown-check.log" 2>&1 & pids+=("$!")
    for pid in "${pids[@]}"; do if ! wait "$pid"; then failed=true; fi; done
    for kind in hosts storage ip shutdown; do cat "$work/$kind-check.log"; done
    [[ "$failed" == false ]] || fail 'Live replacement preflight failed'
}
apply() {
    local operation="$1" kind="$2" name="handoff-$1-$(date -u +%Y%m%d%H%M%S)-$RANDOM"
    shift 2
    phase="$operation"
    guard
    if [[ "$mode" == --execute ]]; then require_stopped; fi
    bash "$directory/morrowpal-infrastructure-change-set.sh" staging "$kind" "$name" "$@"
    # Revalidate after change-set creation, before execution.
    guard
    if [[ "$mode" == --execute ]]; then require_stopped; fi
    bash "$directory/execute-staging-replacement-change-set.sh" "$operation" "morrowpal-staging-$kind" "$name"
    printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$operation" "$name" >>"$record_path.events"
}
guard
bash "$directory/check-replacement-images.sh" staging "$record"
printf 'Staging handoff target: %s; storage=%s, IP=%s, shutdown=%s/%s.\n' "$target" "$storage_host" "$ip_host" "$shutdown_host" "$shutdown_state"
if [[ "$mode" == --dry-run ]]; then printf 'Read-only preflight complete; no changes.\n'; exit 0; fi
if [[ "$mode" == --enable-shutdown ]]; then
    [[ "$storage_host" == "$target" && "$ip_host" == "$target" && "$shutdown_host" == "$target" ]] || fail 'Cannot enable shutdown on an incomplete handoff'
    active="$(awk '$1 == "morrowpal_ec2_stack_name:" { print $2 }' "$vars")"
    [[ "$active" == "$(jq -r --arg target "$target" '.[$target].stackName' "$record")" ]] || fail 'Active stack differs from target'
    instances
    other="$original"; [[ "$target" != original ]] || other="$candidate"
    jq -e --arg other "$other" '[.Reservations[].Instances[] | select(.InstanceId == $other) | .State.Name] == ["stopped"]' "$work/instances.json" >/dev/null || fail 'Other host must remain stopped'
    if [[ "$shutdown_state" != ENABLED ]]; then apply auto-stop auto-stop; fi
    bash "$directory/check-replacement-shutdown.sh" staging "$record" "$target" ENABLED
    exit 0
fi
require_stopped
if [[ "$shutdown_state" != DISABLED ]]; then apply auto-stop auto-stop --disable-auto-stop; fi
bindings
bash "$directory/check-replacement-shutdown.sh" staging "$record" "$shutdown_host" DISABLED
# Wait out the schedule's maximum retry age before any later startup. The preparation wrapper enforces this timestamp.
jq -n --arg target "$target" --argjson notBefore "$(( $(date +%s) + 305 ))" \
    '{target:$target,startNotBeforeEpoch:$notBefore}' >"$record_path.handoff.json"
phase=snapshot
guard
require_stopped
volume="$(jq -r .data.volumeId "$record")"
aws ec2 create-snapshot --volume-id "$volume" --description 'MorrowPal staging host handoff recovery' \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Environment,Value=staging},{Key=Application,Value=morrowpal}]' \
    --region "$region" --output json >"$work/snapshot.json"
snapshot="$(jq -er '.SnapshotId | select(test("^snap-([0-9a-f]{8}|[0-9a-f]{17})$"))' "$work/snapshot.json")"
printf '%s snapshot %s\n' "$(date -u +%FT%TZ)" "$snapshot" >>"$record_path.events"
aws ec2 wait snapshot-completed --snapshot-ids "$snapshot" --region "$region"
[[ "$(sha256sum "$record_path" | cut -d' ' -f1)" == "$(sha256sum "$record" | cut -d' ' -f1)" ]] || fail 'Replacement record changed during handoff'
jq --arg snapshot "$snapshot" '.data.snapshotId=$snapshot' "$record" >"$work/new-record.json"
cp "$work/new-record.json" "$record"
bash "$directory/validate-replacement-record.sh" staging "$record" >/dev/null
cp "$record" "$record_path.tmp"
mv -- "$record_path.tmp" "$record_path"
guard
if [[ "$storage_host" != detached && "$storage_host" != "$target" ]]; then apply detach mysql-storage --detach-mysql-volume; fi
bindings
[[ "$storage_host" == detached || "$storage_host" == "$target" ]] || fail 'Data attachment was not removed'
phase=select-active-stack
require_stopped
desired="$(jq -r --arg target "$target" '.[$target].stackName' "$record")"
[[ "$(rg -c '^morrowpal_ec2_stack_name:' "$vars")" == 1 ]] || fail 'Expected exactly one active-stack setting'
awk -v desired="$desired" '{if ($1 == "morrowpal_ec2_stack_name:") print "morrowpal_ec2_stack_name: " desired; else print}' "$vars" >"$work/vars.yml"
cp "$work/vars.yml" "$vars"
bash "$directory/validate-replacement-record.sh" staging "$record" >/dev/null
bindings
if [[ "$ip_host" != "$target" ]]; then apply public-ip public-ip; fi
bindings
if [[ "$storage_host" != "$target" ]]; then apply attach mysql-storage; fi
bindings
if [[ "$shutdown_host" != "$target" ]]; then apply auto-stop auto-stop --disable-auto-stop; fi
guard
require_stopped
[[ "$storage_host" == "$target" && "$ip_host" == "$target" && "$shutdown_host" == "$target" && "$shutdown_state" == DISABLED ]] || fail 'Handoff did not converge'
phase=complete
printf 'Infrastructure handoff complete; BOTH hosts remain stopped and nightly shutdown is paused. Verify host trust, prepare retained storage, deploy/verify the recorded releases, then enable shutdown.\n'
