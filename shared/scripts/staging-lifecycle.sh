#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_directory="$(cd -- "$script_directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: staging-lifecycle.sh start|stop|status [--dry-run]\n'; }
if [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
[[ $# == 1 || ( $# == 2 && "$2" == --dry-run ) ]] || { usage >&2; exit 2; }
readonly action="$1" dry_run="${2:-}"
case "$action" in start|stop|status) ;; *) usage >&2; exit 2 ;; esac
for command in aws jq ansible ansible-inventory flock; do
    command -v "$command" >/dev/null || fail "Required command not found: $command"
done
cd "$repository_directory"
export ANSIBLE_CONFIG="$repository_directory/ansible.cfg"
export ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote
for variable in ANSIBLE_INVENTORY ANSIBLE_PRIVATE_KEY_FILE ANSIBLE_REMOTE_USER \
    ANSIBLE_CONNECTION ANSIBLE_SSH_ARGS ANSIBLE_SSH_COMMON_ARGS ANSIBLE_SSH_EXTRA_ARGS; do
    [[ -z "${!variable:-}" ]] || fail "Unset $variable; lifecycle commands select connection settings"
done
umask 077
work_directory=$(mktemp -d)
trap 'rm -rf -- "$work_directory"' EXIT
cp environments/staging/vars.yml "$work_directory/vars.yml"
ansible localhost -i localhost, --connection local -m ansible.builtin.template \
    --args "src=$repository_directory/shared/runtime/cloudformation.env.j2 dest=$work_directory/identity.env mode=0600" \
    -e "@$work_directory/vars.yml" >/dev/null
# shellcheck source=/dev/null
source "$work_directory/identity.env"
[[ "$MORROWPAL_ENVIRONMENT" == staging && "$MORROWPAL_STACK_PREFIX" == morrowpal-staging \
    && "$MORROWPAL_INSTANCE_NAME" == morrowpal-staging-01 \
    && "$MORROWPAL_EC2_KEY_NAME" == morrowpal-staging-01 \
    && "${MORROWPAL_SSH_PRIVATE_KEY_FILE##*/}" == morrowpal-staging-01.pem ]] \
    || fail 'Configuration is not the staging environment'
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$MORROWPAL_AWS_REGION" ]] \
        || fail "$variable does not match the staging Region"
done
aws_region="$MORROWPAL_AWS_REGION"
[[ $(aws sts get-caller-identity --region "$aws_region" --query Account --output text) == "$MORROWPAL_AWS_ACCOUNT_ID" ]] \
    || fail 'AWS account does not match staging'
ansible-inventory -i environments/staging/inventory.ini --list >"$work_directory/source-inventory.json"
jq -e --arg host "$MORROWPAL_SSH_HOST_ALIAS" --arg ip "$MORROWPAL_PUBLIC_IPV4" \
    --arg user "$MORROWPAL_SSH_USER" --arg key "$MORROWPAL_SSH_PRIVATE_KEY_FILE" \
    --arg ssh "-o UserKnownHostsFile=$MORROWPAL_SSH_KNOWN_HOSTS_FILE -o StrictHostKeyChecking=accept-new" '
    .morrowpal_hosts.hosts == [$host] and (._meta.hostvars | keys) == [$host]
    and (._meta.hostvars[$host] | keys) == ["ansible_host", "ansible_ssh_common_args", "ansible_ssh_private_key_file", "ansible_user"]
    and (._meta.hostvars[$host] | .ansible_host == $ip and .ansible_user == $user
        and .ansible_ssh_private_key_file == $key and .ansible_ssh_common_args == $ssh)
' "$work_directory/source-inventory.json" >/dev/null || fail 'Inventory does not match staging'
jq --arg host "$MORROWPAL_SSH_HOST_ALIAS" '
    {all:{children:{morrowpal_hosts:{hosts:{($host):._meta.hostvars[$host]}}}}}
' "$work_directory/source-inventory.json" >"$work_directory/inventory.json"
host_command() {
    ansible morrowpal_hosts -i "$work_directory/inventory.json" -e "@$work_directory/vars.yml" \
        --connection ssh --user "$MORROWPAL_SSH_USER" --private-key "$MORROWPAL_SSH_PRIVATE_KEY_FILE" \
        -e ansible_port=22 --become "$@"
}
output() {
    jq -er --arg key "$2" '.Stacks[0].Outputs[] | select(.OutputKey == $key) | .OutputValue | select(length > 0)' "$work_directory/$1.json"
}
validate_target() {
    local kind profile role allocation
    for kind in ec2 ec2-access public-ip; do
        aws cloudformation describe-stacks --stack-name "$MORROWPAL_STACK_PREFIX-$kind" \
            --region "$aws_region" --output json >"$work_directory/$kind.json"
        jq -e --arg prefix "arn:aws:cloudformation:$aws_region:$MORROWPAL_AWS_ACCOUNT_ID:stack/$MORROWPAL_STACK_PREFIX-$kind/" '
            (.Stacks | length) == 1 and (.Stacks[0].StackId | startswith($prefix))
            and (.Stacks[0].StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","UPDATE_ROLLBACK_COMPLETE"))
        ' "$work_directory/$kind.json" >/dev/null || fail 'Stack identity or state does not match staging'
    done
    instance_id=$(output ec2 InstanceId)
    profile=$(output ec2-access InstanceProfileArn)
    role=$(output ec2-access RoleArn)
    allocation=$(output public-ip AllocationId)
    [[ "$profile" == "arn:aws:iam::$MORROWPAL_AWS_ACCOUNT_ID:instance-profile/"* \
        && "$role" == "arn:aws:iam::$MORROWPAL_AWS_ACCOUNT_ID:role/"* \
        && $(output public-ip PublicIp) == "$MORROWPAL_PUBLIC_IPV4" \
        && $(output ec2 AvailabilityZone) == "$MORROWPAL_AVAILABILITY_ZONE" ]] || fail 'Cross-stack bindings do not match staging'
    aws iam get-instance-profile --instance-profile-name "${profile##*/}" --region "$aws_region" \
        --output json >"$work_directory/profile.json"
    jq -e --arg profile "$profile" --arg role "$role" '
        .InstanceProfile.Arn == $profile and [.InstanceProfile.Roles[].Arn] == [$role]
    ' "$work_directory/profile.json" >/dev/null || fail 'Role does not match staging access stack'
    aws ec2 describe-instances --instance-ids "$instance_id" --region "$aws_region" \
        --output json >"$work_directory/instance.json"
    jq -e --arg id "$instance_id" --arg account "$MORROWPAL_AWS_ACCOUNT_ID" \
        --arg vpc "$MORROWPAL_VPC_ID" --arg subnet "$MORROWPAL_SUBNET_ID" --arg group "$MORROWPAL_SECURITY_GROUP_ID" \
        --arg zone "$MORROWPAL_AVAILABILITY_ZONE" --arg key "$MORROWPAL_EC2_KEY_NAME" \
        --arg name "$MORROWPAL_INSTANCE_NAME" --arg profile "$profile" '
        (.Reservations | length) == 1 and .Reservations[0].OwnerId == $account
        and (.Reservations[0].Instances | length) == 1
        and (.Reservations[0].Instances[0] | .InstanceId == $id and .VpcId == $vpc
            and .SubnetId == $subnet and [.SecurityGroups[].GroupId] == [$group]
            and .Placement.AvailabilityZone == $zone and .KeyName == $key
            and .IamInstanceProfile.Arn == $profile
            and any(.Tags[]; .Key == "Environment" and .Value == "staging")
            and any(.Tags[]; .Key == "Application" and .Value == "morrowpal")
            and any(.Tags[]; .Key == "Name" and .Value == $name)
            and any(.Tags[]; .Key == "aws:cloudformation:stack-name" and .Value == "morrowpal-staging-ec2")
            and (.State.Name | IN("running","stopped","pending","stopping")))
    ' "$work_directory/instance.json" >/dev/null || fail 'Instance does not match staging'
    aws ec2 describe-addresses --allocation-ids "$allocation" --region "$aws_region" \
        --output json >"$work_directory/address.json"
    jq -e --arg ip "$MORROWPAL_PUBLIC_IPV4" --arg id "$instance_id" --arg allocation "$allocation" '
        (.Addresses | length) == 1 and .Addresses[0].PublicIp == $ip
        and .Addresses[0].InstanceId == $id and .Addresses[0].AllocationId == $allocation
    ' "$work_directory/address.json" >/dev/null || fail 'Elastic IP is not bound to staging'
    instance_state=$(jq -r '.Reservations[0].Instances[0].State.Name' "$work_directory/instance.json")
}
validate_target
readonly selected_instance="$instance_id"
printf 'Staging: account %s, Region %s, instance %s, IP %s, state %s; action %s.\n' \
    "$MORROWPAL_AWS_ACCOUNT_ID" "$aws_region" "$instance_id" "$MORROWPAL_PUBLIC_IPV4" "$instance_state" "$action"
[[ "$dry_run" != --dry-run ]] || { printf 'Dry run complete; no changes or host connection.\n'; exit 0; }
if [[ "$action" == status ]]; then
    [[ "$instance_state" != running ]] || host_command -m ansible.builtin.command --args '/usr/local/sbin/morrowpal-service status'
    exit 0
fi
exec 9>"/tmp/morrowpal-staging-lifecycle-$MORROWPAL_AWS_ACCOUNT_ID-$aws_region.lock"
flock --exclusive --nonblock 9 || fail 'Another local staging lifecycle command is running'
validate_target
[[ "$instance_id" == "$selected_instance" ]] || fail 'Staging instance changed during validation'
case "$instance_state" in running|stopped) ;; *) fail 'Instance is transitioning; wait and retry' ;; esac
if [[ "$action" == stop ]]; then
    if [[ "$instance_state" == running ]]; then
        host_command -m ansible.builtin.shell --args 'set -eu
flock --exclusive --nonblock /run/morrowpal-deploy.lock systemctl stop morrowpal.service
test "$(systemctl show morrowpal.service --property ActiveState --value)" = inactive
test -z "$(docker ps -q --filter label=com.docker.compose.project=morrowpal)"'
        validate_target
        [[ "$instance_id" == "$selected_instance" && "$instance_state" == running ]] || fail 'Staging changed before stop'
        aws ec2 stop-instances --instance-ids "$selected_instance" --region "$aws_region" --output json
        aws ec2 wait instance-stopped --instance-ids "$selected_instance" --region "$aws_region"
    fi
    printf 'Staging is stopped. Retained volumes and the Elastic IP remain allocated.\n'
else
    if [[ "$instance_state" == stopped ]]; then
        aws ec2 start-instances --instance-ids "$selected_instance" --region "$aws_region" --output json
        aws ec2 wait instance-running --instance-ids "$selected_instance" --region "$aws_region"
    fi
    host_command -m ansible.builtin.wait_for_connection --args 'timeout=180'
    host_command -m ansible.builtin.shell --args 'for attempt in $(seq 1 180); do
if systemctl is-active --quiet morrowpal.service; then
    exec /usr/local/sbin/morrowpal-service status
fi
sleep 5
done
exit 1'
    validate_target
    [[ "$instance_id" == "$selected_instance" && "$instance_state" == running ]] || fail 'Staging changed during start'
    printf 'Staging is running and its startup readiness checks passed.\n'
fi
