#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]##*/}" == finish-staging-os-alignment.sh ]]; then
    frozen="$(mktemp "$directory/.staging-finish.XXXXXX")"
    trap 'rm -f -- "$frozen"' EXIT
    cp -- "${BASH_SOURCE[0]}" "$frozen"
    result=0; bash "$frozen" "$@" || result=$?; exit "$result"
fi
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 || ( $# == 4 && ( "$4" == --resume-candidate || "$4" == --resume-rollback ) ) ]] || fail 'Usage: finish-staging-os-alignment.sh RECORD.json PRODUCTION_READONLY_BASELINE.json CERTBOT_EMAIL [--resume-candidate|--resume-rollback]'
record="$(realpath -- "$1")" production="$(realpath -- "$2")" email="$3"
evidence="$(dirname -- "$record")"
cd "$repository"
umask 077
bash "$directory/validate-replacement-record.sh" staging "$record"
region="$(jq -r .region "$record")"
ip="$(jq -r .publicIp.address "$record")"
account="$(jq -r .accountId "$record")"
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$region" ]] || fail 'Region override does not match staging'
done
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] || fail 'AWS account does not match staging'
phase=trust
on_exit() {
    local rc=$?
    if ((rc)); then
        printf 'Alignment stopped at %s; preserving data and attempting normal stops of the recorded staging hosts.\n' "$phase" >&2
        if bash "$directory/check-replacement-hosts.sh" staging "$record" >"$evidence/failure-host-check.log" 2>&1; then
            mapfile -t ids < <(jq -r '.original.instanceId,.candidate.instanceId' "$record")
            aws ec2 stop-instances --instance-ids "${ids[@]}" --region "$region" --output json >"$evidence/failure-normal-stop.json" || true
            aws ec2 wait instance-stopped --instance-ids "${ids[@]}" --region "$region" || true
        fi
    fi
}
trap on_exit EXIT
if [[ ! -s "$record.known-hosts.candidate" ]]; then bash "$directory/trust-staging-host-via-ssm.sh" "$record" candidate; fi
phase=remove-temporary-permission
if aws cloudformation describe-stacks --stack-name morrowpal-staging-ssh-trust-recovery --region "$region" --output json >"$evidence/temporary-ssm-stack.json" 2>"$evidence/temporary-ssm-stack.error"; then
    aws cloudformation describe-stack-resources --stack-name morrowpal-staging-ssh-trust-recovery --region "$region" --output json >"$evidence/temporary-ssm-resources.json"
    jq -e '.StackResources | length == 1 and all(.[]; .ResourceType == "AWS::IAM::Policy")' "$evidence/temporary-ssm-resources.json" >/dev/null || fail 'Temporary stack has unexpected resources'
    aws cloudformation delete-stack --stack-name morrowpal-staging-ssh-trust-recovery --region "$region"
    aws cloudformation wait stack-delete-complete --stack-name morrowpal-staging-ssh-trust-recovery --region "$region"
else
    grep -Fq 'does not exist' "$evidence/temporary-ssm-stack.error" || fail 'Could not inspect temporary SSM stack'
fi
verify() {
    local label="$1"
    for attempt in {1..3}; do
        if ssh -i ../morrowpal-staging-01.pem -o UserKnownHostsFile=environments/staging/known_hosts -o StrictHostKeyChecking=yes \
            "ec2-user@$ip" 'sudo bash -s' <"$directory/capture-host-metadata.sh" >"$evidence/$label-host.json"; then break; fi
        [[ "$attempt" != 3 ]] || fail 'Could not capture eight running containers'
        sleep 5
    done
    node "$directory/verify-replacement-host-metadata.mjs" "$record" "$production" "$evidence/$label-host.json" >"$evidence/$label-verification.json"
    for url in https://api.staging.morrowpal.com/ready https://app.staging.morrowpal.com/ready https://staging.morrowpal.com/ready; do
        curl --fail --silent --show-error --retry 3 --max-time 30 "$url" >/dev/null
        printf '%s ready: %s\n' "$(date -u +%FT%TZ)" "$url"
    done
    curl --fail --silent --show-error --max-time 30 https://app.staging.morrowpal.com/runtime-config.js \
        | node --input-type=module -e 'import fs from "node:fs"; const s=fs.readFileSync(0,"utf8"); if(!s.includes("https://api.staging.morrowpal.com")||!s.includes("morrowpal-staging")||s.includes("https://api.morrowpal.com")) process.exit(1);'
}
wait_for_retry_window() {
    local target="$1" not_before remaining delay
    # Preparation rejects early startup; the batch runner waits for that gate.
    not_before="$(jq -er '.startNotBeforeEpoch | select(type == "number" and . == floor)' "$record.handoff.json")"
    remaining=$(( not_before - $(date +%s) ))
    ((remaining <= 310)) || fail 'Scheduler retry window is unexpectedly far in the future'
    while ((remaining > 0)); do
        printf 'Waiting %s seconds for the paused scheduler retry window before preparing %s.\n' "$remaining" "$target"
        delay="$remaining"; ((delay <= 30)) || delay=30
        sleep "$delay"
        remaining=$(( not_before - $(date +%s) ))
    done
}
prepare() {
    wait_for_retry_window "$1"
    bash "$directory/prepare-staging-replacement.sh" "$record" "$1" "$email"
}
if [[ "${4:-}" != --resume-rollback ]]; then
phase=prepare-candidate
if [[ "${4:-}" == --resume-candidate ]]; then
    bash "$directory/check-replacement-storage.sh" staging "$record" candidate
    bash "$directory/check-replacement-ip.sh" staging "$record" candidate
    bash "$directory/check-replacement-shutdown.sh" staging "$record" candidate DISABLED
    wait_for_retry_window candidate
    bash "$directory/staging-lifecycle.sh" start
else
    prepare candidate
fi
phase=verify-candidate
verify candidate-first
phase=restore-snapshot-check
bash "$directory/verify-staging-snapshot-restore.sh" "$record" candidate
phase=stop-for-rollback
bash "$directory/staging-lifecycle.sh" stop
fi
phase=rollback-infrastructure
bash "$directory/staging-host-handoff.sh" "$record" original --execute
phase=prepare-original
prepare original
phase=verify-original
verify original-rollback
phase=stop-original
bash "$directory/staging-lifecycle.sh" stop
phase=restore-candidate-infrastructure
bash "$directory/staging-host-handoff.sh" "$record" candidate --execute
phase=prepare-final-candidate
prepare candidate
phase=verify-final-candidate
verify candidate-final
phase=enable-nightly-shutdown
bash "$directory/staging-host-handoff.sh" "$record" candidate --enable-shutdown
phase=final-stop
bash "$directory/staging-lifecycle.sh" stop
bash "$directory/check-replacement-shutdown.sh" staging "$record" candidate ENABLED
mapfile -t ids < <(jq -r '.original.instanceId,.candidate.instanceId' "$record")
aws ec2 describe-instances --instance-ids "${ids[@]}" --region "$region" --output json \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,ImageId:ImageId}' >"$evidence/final-instances.json"
jq -e 'length == 2 and all(.[]; .State == "stopped")' "$evidence/final-instances.json" >/dev/null
phase=complete
printf 'All remaining staging OS-alignment pieces completed; candidate selected, rollback verified, nightly shutdown enabled and both hosts stopped.\n'
