#!/usr/bin/env bash
set -Eeuo pipefail
readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly wrapper="$script_directory/staging-lifecycle.sh"
work_directory=$(mktemp -d)
trap 'rm -rf -- "$work_directory"' EXIT
mkdir "$work_directory/bin"
export LIFECYCLE_FIXTURES="$work_directory"
export PATH="$work_directory/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION ANSIBLE_INVENTORY ANSIBLE_PRIVATE_KEY_FILE ANSIBLE_REMOTE_USER \
    ANSIBLE_CONNECTION ANSIBLE_SSH_ARGS ANSIBLE_SSH_COMMON_ARGS ANSIBLE_SSH_EXTRA_ARGS
cat >"$work_directory/identity.env" <<'ENV'
MORROWPAL_ENVIRONMENT=staging
MORROWPAL_STACK_PREFIX=morrowpal-staging
MORROWPAL_AWS_ACCOUNT_ID=123456789012
MORROWPAL_AWS_REGION=us-east-1
MORROWPAL_AVAILABILITY_ZONE=us-east-1a
MORROWPAL_INSTANCE_NAME=morrowpal-staging-01
MORROWPAL_EC2_KEY_NAME=morrowpal-staging-01
MORROWPAL_VPC_ID=vpc-staging
MORROWPAL_SUBNET_ID=subnet-staging
MORROWPAL_SECURITY_GROUP_ID=sg-staging
MORROWPAL_PUBLIC_IPV4=192.0.2.10
MORROWPAL_SSH_HOST_ALIAS=01
MORROWPAL_SSH_USER=ec2-user
MORROWPAL_SSH_PRIVATE_KEY_FILE=../morrowpal-staging-01.pem
MORROWPAL_SSH_KNOWN_HOSTS_FILE=environments/staging/known_hosts
ENV
cat >"$work_directory/bin/ansible" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'ansible %s\n' "$*" >>"$LIFECYCLE_FIXTURES/calls"
if [[ "$1" == localhost ]]; then
    [[ "$*" =~ dest=([^[:space:]]+) ]]
    cp "$LIFECYCLE_FIXTURES/identity.env" "${BASH_REMATCH[1]}"
    case "${LIFECYCLE_CASE:-}" in
        overlay) echo MORROWPAL_ENVIRONMENT=prod >>"${BASH_REMATCH[1]}" ;;
        key) echo MORROWPAL_EC2_KEY_NAME=prod-key >>"${BASH_REMATCH[1]}" ;;
    esac
elif [[ "${LIFECYCLE_CASE:-}" == shutdown && "$*" == *'systemctl stop'* ]]; then
    exit 1
elif [[ "${LIFECYCLE_CASE:-}" == rebind && "$*" == *'systemctl stop'* ]]; then
    touch "$LIFECYCLE_FIXTURES/rebound"
fi
MOCK
cat >"$work_directory/bin/ansible-inventory" <<'MOCK'
#!/usr/bin/env bash
jq -n --arg ip "$(if [[ "${LIFECYCLE_CASE:-}" == inventory ]]; then echo 192.0.2.20; else echo 192.0.2.10; fi)" '
{morrowpal_hosts:{hosts:["01"]},_meta:{hostvars:{"01":{
ansible_host:$ip,ansible_user:"ec2-user",ansible_ssh_private_key_file:"../morrowpal-staging-01.pem",
ansible_ssh_common_args:"-o UserKnownHostsFile=environments/staging/known_hosts -o StrictHostKeyChecking=accept-new"}}}}'
MOCK
cat >"$work_directory/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'aws %s\n' "$*" >>"$LIFECYCLE_FIXTURES/calls"
case "$1 $2" in
    'sts get-caller-identity')
        if [[ "${LIFECYCLE_CASE:-}" == account ]]; then echo 999999999999; else echo 123456789012; fi ;;
    'cloudformation describe-stacks')
        stack=''
        while (($#)); do
            if [[ "$1" == --stack-name ]]; then stack="$2"; break; fi
            shift
        done
        case "$stack" in
            morrowpal-staging-ec2) outputs='{"InstanceId":"i-staging","AvailabilityZone":"us-east-1a"}' ;;
            morrowpal-staging-ec2-access) outputs='{"InstanceProfileArn":"arn:aws:iam::123456789012:instance-profile/staging","RoleArn":"arn:aws:iam::123456789012:role/staging"}' ;;
            morrowpal-staging-public-ip) outputs='{"AllocationId":"eipalloc-staging","PublicIp":"192.0.2.10"}' ;;
            *) exit 2 ;;
        esac
        jq -n --arg stack "$stack" --arg mismatch "${LIFECYCLE_CASE:-}" --argjson outputs "$outputs" '
        {Stacks:[{StackId:("arn:aws:cloudformation:us-east-1:123456789012:stack/" +
            (if $mismatch == "stack" then "morrowpal-prod-ec2" else $stack end) + "/id"),
        StackStatus:"CREATE_COMPLETE",Outputs:($outputs | to_entries | map({OutputKey:.key,OutputValue:.value}))}]}' ;;
    'iam get-instance-profile')
        jq -n --arg role "${LIFECYCLE_CASE:-}" '{InstanceProfile:{Arn:"arn:aws:iam::123456789012:instance-profile/staging",
            Roles:[{Arn:("arn:aws:iam::123456789012:role/" + (if $role == "role" then "prod" else "staging" end))}]}}' ;;
    'ec2 describe-instances')
        if [[ "${LIFECYCLE_CASE:-}" == rebind && -e "$LIFECYCLE_FIXTURES/rebound" ]]; then LIFECYCLE_CASE=tag; fi
        jq -n --arg state "$(cat "$LIFECYCLE_FIXTURES/state")" --arg mismatch "${LIFECYCLE_CASE:-}" '
        {Reservations:[{OwnerId:"123456789012",Instances:[{InstanceId:"i-staging",State:{Name:$state},
        VpcId:"vpc-staging",SubnetId:"subnet-staging",SecurityGroups:[{GroupId:(if $mismatch == "group" then "sg-prod" else "sg-staging" end)}],
        Placement:{AvailabilityZone:"us-east-1a"},KeyName:"morrowpal-staging-01",
        IamInstanceProfile:{Arn:"arn:aws:iam::123456789012:instance-profile/staging"},
        Tags:[{Key:"Environment",Value:(if $mismatch == "tag" then "prod" else "staging" end)},
        {Key:"Application",Value:"morrowpal"},{Key:"Name",Value:"morrowpal-staging-01"},
        {Key:"aws:cloudformation:stack-name",Value:"morrowpal-staging-ec2"}]}]}]}' ;;
    'ec2 describe-addresses')
        jq -n --arg mismatch "${LIFECYCLE_CASE:-}" '{Addresses:[{AllocationId:"eipalloc-staging",PublicIp:"192.0.2.10",
            InstanceId:(if $mismatch == "ip" then "i-prod" else "i-staging" end)}]}' ;;
    'ec2 stop-instances') echo stopped >"$LIFECYCLE_FIXTURES/state" ;;
    'ec2 start-instances') echo running >"$LIFECYCLE_FIXTURES/state" ;;
    'ec2 wait') ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$work_directory/bin/ansible" "$work_directory/bin/ansible-inventory" "$work_directory/bin/aws"
reset_case() {
    export LIFECYCLE_CASE="${1:-}"
    : >"$work_directory/calls"
    rm -f "$work_directory/rebound"
    echo running >"$work_directory/state"
}
assert_no_action() {
    if grep -Eq '^aws ec2 (start-instances|stop-instances)|^ansible morrowpal_hosts ' "$work_directory/calls"; then
        echo 'Unexpected lifecycle mutation or host connection' >&2; exit 1
    fi
}
for mismatch in account inventory stack role group tag ip overlay key; do
    reset_case "$mismatch"
    if "$wrapper" stop >"$work_directory/output" 2>&1; then echo "Accepted mismatch: $mismatch" >&2; exit 1; fi
    assert_no_action
done
reset_case
for arguments in '' 'prod stop' 'stop --instance-id i-prod' 'destroy'; do
    # Intentional word splitting tests invalid argument lists.
    # shellcheck disable=SC2086
    if "$wrapper" $arguments >"$work_directory/output" 2>&1; then echo 'Accepted invalid arguments' >&2; exit 1; fi
done
assert_no_action
for action in start stop status; do
    reset_case
    "$wrapper" "$action" --dry-run >/dev/null
    assert_no_action
done
reset_case shutdown
if "$wrapper" stop >"$work_directory/output" 2>&1; then echo 'Ignored failed graceful stop' >&2; exit 1; fi
! grep -q '^aws ec2 stop-instances' "$work_directory/calls"
reset_case rebind
if "$wrapper" stop >"$work_directory/output" 2>&1; then echo 'Ignored target change after graceful stop' >&2; exit 1; fi
! grep -q '^aws ec2 stop-instances' "$work_directory/calls"
reset_case
"$wrapper" stop >/dev/null
[[ $(cat "$work_directory/state") == stopped ]]
grep -q '^aws ec2 wait instance-stopped' "$work_directory/calls"
"$wrapper" start >/dev/null
[[ $(cat "$work_directory/state") == running ]]
grep -q '^aws ec2 wait instance-running' "$work_directory/calls"
grep -q 'ansible.builtin.wait_for_connection' "$work_directory/calls"
grep -q 'systemctl is-active --quiet morrowpal.service' "$work_directory/calls"
reset_case
echo stopped >"$work_directory/state"
"$wrapper" status >/dev/null
assert_no_action
"$wrapper" stop >/dev/null
assert_no_action
reset_case
echo stopping >"$work_directory/state"
if "$wrapper" start >"$work_directory/output" 2>&1; then echo 'Accepted transitioning instance' >&2; exit 1; fi
assert_no_action
printf 'Staging lifecycle guards, dry runs, graceful stop, and startup waits passed.\n'
