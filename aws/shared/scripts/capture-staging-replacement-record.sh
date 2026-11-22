#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Usage: capture-staging-replacement-record.sh CANDIDATE_STACK HOST_BASELINE.json NEW_RECORD.json'
candidate_stack="$1" baseline="$(realpath -- "$2")" record_path="$(realpath -m -- "$3")"
[[ "$candidate_stack" =~ ^morrowpal-staging-ec2-[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] || fail 'Candidate stack must belong to staging'
[[ ! -e "$record_path" ]] || fail 'Record already exists; do not overwrite a recovery record'
exec 9>/tmp/morrowpal-staging-host-handoff.lock
flock --exclusive --nonblock 9 || fail 'Another staging operation is running'
umask 077
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
ANSIBLE_CONFIG="$repository/ansible.cfg" ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
    ansible localhost -i localhost, --connection local -m ansible.builtin.template \
    --args "src=$repository/shared/runtime/cloudformation.env.j2 dest=$work/env mode=0600" \
    -e "@$repository/environments/staging/vars.yml" >/dev/null
source "$work/env"
[[ "$MORROWPAL_ENVIRONMENT" == staging && "$MORROWPAL_STACK_PREFIX" == morrowpal-staging && "$MORROWPAL_EC2_STACK_NAME" == morrowpal-staging-ec2 ]] || fail 'Capture requires the original staging stack still selected'
account="$MORROWPAL_AWS_ACCOUNT_ID" region="$MORROWPAL_AWS_REGION"
[[ "$(aws sts get-caller-identity --region "$region" --query Account --output text)" == "$account" ]] || fail 'AWS account mismatch'
for spec in 'original morrowpal-staging-ec2' "candidate $candidate_stack" 'storage morrowpal-staging-mysql-storage' 'ip morrowpal-staging-public-ip'; do
    read -r kind name <<<"$spec"
    aws cloudformation describe-stacks --stack-name "$name" --region "$region" --output json >"$work/$kind-stack.json"
    jq -e --arg prefix "arn:aws:cloudformation:$region:$account:stack/$name/" '
      (.Stacks | length) == 1 and (.Stacks[0].StackId | startswith($prefix)) and (.Stacks[0].StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"))
    ' "$work/$kind-stack.json" >/dev/null || fail 'Stack identity/state mismatch'
done
output() { jq -er --arg key "$2" '[.Stacks[0].Outputs[] | select(.OutputKey == $key) | .OutputValue] | select(length == 1) | .[0]' "$work/$1-stack.json"; }
original="$(output original InstanceId)" candidate="$(output candidate InstanceId)" volume="$(output storage VolumeId)"
aws ec2 describe-instances --instance-ids "$original" "$candidate" --region "$region" --output json >"$work/instances.json"
jq -e --arg account "$account" --arg original "$original" --arg candidate "$candidate" --arg stack "$candidate_stack" \
    --arg vpc "$MORROWPAL_VPC_ID" --arg subnet "$MORROWPAL_SUBNET_ID" --arg group "$MORROWPAL_SECURITY_GROUP_ID" '
    all(.Reservations[]; .OwnerId == $account) and ([.Reservations[].Instances[].InstanceId] | sort) == ([$original,$candidate] | sort)
    and [.Reservations[].Instances[] | select(.InstanceId == $original) | .State.Name] == ["stopped"]
    and ([.Reservations[].Instances[] | select(.InstanceId == $candidate)][0] |
      .VpcId == $vpc and .SubnetId == $subnet and [.SecurityGroups[].GroupId] == [$group]
      and (.BlockDeviceMappings | length) == 1
      and any(.Tags[]; .Key == "Environment" and .Value == "staging")
      and any(.Tags[]; .Key == "aws:cloudformation:stack-name" and .Value == $stack))
' "$work/instances.json" >/dev/null || fail 'Original must be stopped; candidate must be a fresh staging host with only a root disk'
aws ec2 stop-instances --instance-ids "$candidate" --region "$region" --output json >/dev/null
aws ec2 wait instance-stopped --instance-ids "$candidate" --region "$region"
aws ec2 describe-volumes --volume-ids "$volume" --region "$region" --output json >"$work/volume.json"
jq -e --arg original "$original" --arg volume "$volume" --arg zone "$MORROWPAL_AVAILABILITY_ZONE" '
    (.Volumes | length) == 1 and (.Volumes[0] | .VolumeId == $volume and .AvailabilityZone == $zone and .Encrypted == true
      and any(.Tags[]; .Key == "Environment" and .Value == "staging")
      and [.Attachments[].InstanceId] == [$original] and .Attachments[0].State == "attached")
' "$work/volume.json" >/dev/null || fail 'Snapshot source is not the original staging data volume'
aws ec2 create-snapshot --volume-id "$volume" --description 'MorrowPal staging replacement baseline' \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Environment,Value=staging},{Key=Application,Value=morrowpal}]' \
    --region "$region" --output json >"$work/snapshot.json"
snapshot="$(jq -er '.SnapshotId | select(test("^snap-([0-9a-f]{8}|[0-9a-f]{17})$"))' "$work/snapshot.json")"
aws ec2 wait snapshot-completed --snapshot-ids "$snapshot" --region "$region"
jq -n --slurpfile baseline "$baseline" --slurpfile instances "$work/instances.json" --slurpfile policy "$repository/shared/ec2-image.json" \
    --arg original "$original" --arg candidate "$candidate" --arg candidateStack "$candidate_stack" --arg account "$account" --arg region "$region" \
    --arg zone "$MORROWPAL_AVAILABILITY_ZONE" --arg volume "$volume" --arg snapshot "$snapshot" --arg allocation "$(output ip AllocationId)" --arg ip "$MORROWPAL_PUBLIC_IPV4" \
    --arg vpc "$MORROWPAL_VPC_ID" --arg subnet "$MORROWPAL_SUBNET_ID" --arg group "$MORROWPAL_SECURITY_GROUP_ID" --arg key "$MORROWPAL_EC2_KEY_NAME" '
    $baseline[0] as $b | [$instances[0].Reservations[].Instances[]] as $hosts |
    def host($id;$stack): $hosts[] | select(.InstanceId == $id) | .RootDeviceName as $root |
      {stackName:$stack,instanceId:$id,amiId:.ImageId,rootVolumeId:([.BlockDeviceMappings[] | select(.DeviceName == $root) | .Ebs.VolumeId] | if length == 1 then .[0] else error("Ambiguous root") end)};
    def image($component): ("\($account).dkr.ecr.\($region).amazonaws.com/morrowpal/staging/\($component)") as $uri |
      ([$b.containers[].image | select(startswith($uri+":"))] | unique) as $refs |
      ([$b.images[].repoDigests[]? | select(startswith($uri+"@"))] | unique) as $digests |
      if ($refs | length) == 1 and ($digests | length) == 1 then {tag:($refs[0]|split(":")|last),digest:($digests[0]|split("@")|last)} else error("Missing/ambiguous baseline image") end;
    image("backend-api") as $api | image("backend-job") as $job |
    if $api.tag != $job.tag or $b.filesystem != "xfs" then error("Baseline backend tags or filesystem mismatch") else
    {schemaVersion:1,environment:"staging",accountId:$account,region:$region,availabilityZone:$zone,
     original:host($original;"morrowpal-staging-ec2"),candidate:(host($candidate;$candidateStack)+{imageName:$policy[0].name}),
     data:{volumeId:$volume,filesystemUuid:$b.filesystemUuid,snapshotId:$snapshot},publicIp:{allocationId:$allocation,address:$ip},
     network:{vpcId:$vpc,subnetId:$subnet,securityGroupId:$group,keyName:$key},
     releases:{backend:{tag:$api.tag,apiDigest:$api.digest,jobDigest:$job.digest},app:image("app"),website:image("website")},
     shutdown:{groupName:"morrowpal-staging-auto-stop",scheduleName:"morrowpal-staging-auto-stop-nightly",originalTargetInstanceId:$original}} end
' >"$work/record.json"
bash "$directory/validate-replacement-record.sh" staging "$work/record.json"
cp "$work/record.json" "$record_path"
cp "$baseline" "$record_path.original-host-baseline.json"
bash "$directory/check-replacement-hosts.sh" staging "$work/record.json"
bash "$directory/check-replacement-storage.sh" staging "$work/record.json" original
bash "$directory/check-replacement-ip.sh" staging "$work/record.json" original
bash "$directory/check-replacement-images.sh" staging "$work/record.json"
bash "$directory/check-replacement-shutdown.sh" staging "$work/record.json" original ENABLED
printf 'Captured staging replacement record: %s; both hosts stopped.\n' "$record_path"
