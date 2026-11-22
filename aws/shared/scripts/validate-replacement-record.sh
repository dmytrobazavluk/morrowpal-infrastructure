#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: validate-replacement-record.sh ENVIRONMENT RECORD.json\nLocal validation only; AWS resource identities must be revalidated before cutover.\n'; }
if [[ $# == 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
environment="$1" record_file="$2"
case "$environment" in staging|prod) ;; *) fail 'Environment must be staging or prod' ;; esac
[[ -f "$record_file" ]] || fail 'Replacement record file not found'
for tool in ansible jq; do command -v "$tool" >/dev/null || fail "Required command not found: $tool"; done
umask 077
rendered_environment="$(mktemp)"
trap 'rm -f -- "$rendered_environment"' EXIT
ANSIBLE_CONFIG="$repository_directory/ansible.cfg" ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
    ansible localhost -i localhost, --connection local -m ansible.builtin.template \
    --args "src=$repository_directory/shared/runtime/cloudformation.env.j2 dest=$rendered_environment mode=0600" \
    -e "@$repository_directory/environments/$environment/vars.yml" >/dev/null \
    || fail 'Could not render selected environment configuration'
# Public infrastructure bindings only; no secret values are resolved.
source "$rendered_environment"
[[ "$MORROWPAL_ENVIRONMENT" == "$environment" && "$MORROWPAL_STACK_PREFIX" == "morrowpal-$environment" ]] \
    || fail 'Configuration does not match selected environment'

jq --exit-status --slurp --arg environment "$environment" \
    --arg account "$MORROWPAL_AWS_ACCOUNT_ID" --arg region "$MORROWPAL_AWS_REGION" \
    --arg zone "$MORROWPAL_AVAILABILITY_ZONE" --arg active "$MORROWPAL_EC2_STACK_NAME" \
    --arg prefix "$MORROWPAL_STACK_PREFIX" --arg ip "$MORROWPAL_PUBLIC_IPV4" \
    --arg vpc "$MORROWPAL_VPC_ID" --arg subnet "$MORROWPAL_SUBNET_ID" \
    --arg group "$MORROWPAL_SECURITY_GROUP_ID" --arg key "$MORROWPAL_EC2_KEY_NAME" \
    --slurpfile policy "$repository_directory/shared/ec2-image.json" '
    def fields($names): type == "object" and (keys == ($names | sort));
    def id($prefix): type == "string" and test("^" + $prefix + "-([0-9a-f]{8}|[0-9a-f]{17})$");
    def stack: type == "string" and length <= 128
      and test("^" + $prefix + "-ec2(-[A-Za-z0-9]+(-[A-Za-z0-9]+)*)?$");
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def tag: type == "string" and test("^build-[1-9][0-9]*-[0-9a-f]{7}$");
    def image: fields(["tag","digest"]) and (.tag | tag) and (.digest | digest);
    length == 1 and (.[0] |
      fields(["schemaVersion","environment","accountId","region","availabilityZone",
              "original","candidate","data","publicIp","network","releases","shutdown"])
      and .schemaVersion == 1 and .environment == $environment
      and .accountId == $account and (.accountId | test("^[0-9]{12}$"))
      and .region == $region and .availabilityZone == $zone
      and (.original | fields(["stackName","instanceId","amiId","rootVolumeId"])
        and (.stackName | stack) and (.instanceId | id("i"))
        and (.amiId | id("ami")) and (.rootVolumeId | id("vol")))
      and (.candidate | fields(["stackName","instanceId","amiId","imageName","rootVolumeId"])
        and (.stackName | stack) and (.stackName != ($prefix + "-ec2"))
        and (.instanceId | id("i")) and (.amiId | id("ami"))
        and .imageName == $policy[0].name and (.rootVolumeId | id("vol")))
      and .original.stackName != .candidate.stackName
      and .original.instanceId != .candidate.instanceId
      and ($active == .original.stackName or $active == .candidate.stackName)
      and (.data | fields(["volumeId","filesystemUuid","snapshotId"])
        and (.volumeId | id("vol")) and (.snapshotId | id("snap"))
        and (.filesystemUuid | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
      and ([.original.rootVolumeId,.candidate.rootVolumeId,.data.volumeId] | unique | length == 3)
      and (.publicIp | fields(["allocationId","address"])
        and (.allocationId | id("eipalloc")) and .address == $ip)
      and (.network | fields(["vpcId","subnetId","securityGroupId","keyName"])
        and .vpcId == $vpc and (.vpcId | id("vpc"))
        and .subnetId == $subnet and (.subnetId | id("subnet"))
        and .securityGroupId == $group and (.securityGroupId | id("sg")) and .keyName == $key)
      and (.releases | fields(["backend","app","website"])
        and (.backend | fields(["tag","apiDigest","jobDigest"]) and (.tag | tag)
          and (.apiDigest | digest) and (.jobDigest | digest))
        and (.app | image) and (.website | image))
      and (if $environment == "staging" then
        .shutdown as $shutdown | .original.instanceId as $original |
        ($shutdown | fields(["groupName","scheduleName","originalTargetInstanceId"])
          and .groupName == ($prefix + "-auto-stop")
          and .scheduleName == ($prefix + "-auto-stop-nightly")
          and .originalTargetInstanceId == $original)
        else .shutdown == null end))
    ' "$record_file" >/dev/null 2>/dev/null \
    || fail 'Replacement record is invalid or does not match the selected environment and image policy'
printf 'Replacement record matches %s configuration. Live AWS identity checks are still required.\n' "$environment"
