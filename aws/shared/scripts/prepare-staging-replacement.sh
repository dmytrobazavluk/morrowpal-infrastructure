#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${BASH_SOURCE[0]##*/}" == prepare-staging-replacement.sh ]]; then
    frozen="$(mktemp "$directory/.staging-prepare.XXXXXX")"
    trap 'rm -f -- "$frozen"' EXIT
    cp -- "${BASH_SOURCE[0]}" "$frozen"
    result=0
    bash "$frozen" "$@" || result=$?
    exit "$result"
fi
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Usage: prepare-staging-replacement.sh RECORD.json original|candidate CERTBOT_EMAIL'
record_path="$(realpath -- "$1")" target="$2" email="$3"
case "$target" in original|candidate) ;; *) fail 'Invalid target' ;; esac
[[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail 'Invalid Certbot email'
exec 9>/tmp/morrowpal-staging-host-handoff.lock
flock --exclusive --nonblock 9 || fail 'Another staging operation is running'
umask 077
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cd "$repository"
cp -- "$record_path" "$work/record.json"
record="$work/record.json"
bash "$directory/validate-replacement-record.sh" staging "$record"
bash "$directory/check-replacement-hosts.sh" staging "$record"
bash "$directory/check-replacement-storage.sh" staging "$record" "$target"
bash "$directory/check-replacement-ip.sh" staging "$record" "$target"
bash "$directory/check-replacement-shutdown.sh" staging "$record" "$target" DISABLED
bash "$directory/check-replacement-images.sh" staging "$record"
jq -e --arg target "$target" --argjson now "$(date +%s)" \
    '.target == $target and (.startNotBeforeEpoch | type == "number") and .startNotBeforeEpoch <= $now' \
    "$record_path.handoff.json" >/dev/null || fail 'Wait for the paused scheduler retry window recorded in the handoff file'
export ANSIBLE_CONFIG="$repository/ansible.cfg" ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote
for variable in ANSIBLE_INVENTORY ANSIBLE_PRIVATE_KEY_FILE ANSIBLE_REMOTE_USER ANSIBLE_CONNECTION ANSIBLE_SSH_ARGS ANSIBLE_SSH_COMMON_ARGS ANSIBLE_SSH_EXTRA_ARGS; do
    [[ -z "${!variable:-}" ]] || fail "Unset $variable; preparation selects the staging connection"
done
ansible localhost -i localhost, --connection local -m ansible.builtin.template \
    --args "src=$repository/shared/runtime/cloudformation.env.j2 dest=$work/env mode=0600" \
    -e "@$repository/environments/staging/vars.yml" >/dev/null
source "$work/env"
[[ "$MORROWPAL_ENVIRONMENT" == staging && "$MORROWPAL_STACK_PREFIX" == morrowpal-staging \
    && "$MORROWPAL_EC2_STACK_NAME" == "$(jq -r --arg target "$target" '.[$target].stackName' "$record")" \
    && "$MORROWPAL_SSH_KNOWN_HOSTS_FILE" == environments/staging/known_hosts \
    && "${MORROWPAL_SSH_PRIVATE_KEY_FILE##*/}" == morrowpal-staging-01.pem ]] || fail 'Preparation configuration is not the selected staging host'
region="$MORROWPAL_AWS_REGION" account="$MORROWPAL_AWS_ACCOUNT_ID"
instance="$(jq -r --arg target "$target" '.[$target].instanceId' "$record")"
other="$(jq -r --arg target "$target" 'if $target == "candidate" then .original.instanceId else .candidate.instanceId end' "$record")"
aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$instance" --region "$region" --output json >"$work/interfaces.json"
interface="$(jq -er --arg instance "$instance" --arg account "$account" --arg vpc "$MORROWPAL_VPC_ID" --arg subnet "$MORROWPAL_SUBNET_ID" '
    [.NetworkInterfaces[] | select(.Attachment.DeviceIndex == 0 and .Attachment.InstanceId == $instance)]
    | select(length == 1) | .[0] | select(.OwnerId == $account and .VpcId == $vpc and .SubnetId == $subnet)
    | .NetworkInterfaceId | select(test("^eni-([0-9a-f]{8}|[0-9a-f]{17})$"))
' "$work/interfaces.json")" || fail 'Cannot identify the staging primary interface for tagging'
aws ec2 create-tags --resources "$interface" --tags Key=Environment,Value=staging Key=Application,Value=morrowpal --region "$region"
aws ec2 describe-instances --instance-ids "$other" --region "$region" --output json >"$work/other.json"
jq -e --arg other "$other" --arg account "$account" '
    [.Reservations[].OwnerId] == [$account] and [.Reservations[].Instances[] | {id:.InstanceId,state:.State.Name}] == [{id:$other,state:"stopped"}]
' "$work/other.json" >/dev/null || fail 'Other host must remain stopped'
aws ec2 start-instances --instance-ids "$instance" --region "$region" --output json >/dev/null
aws ec2 wait instance-running --instance-ids "$instance" --region "$region"
known_hosts="$MORROWPAL_SSH_KNOWN_HOSTS_FILE"
[[ ! -L "$known_hosts" ]] || fail 'Known-hosts file must not be a symlink'
if [[ ! -e "$record_path.known-hosts.original" ]]; then cp -- "$known_hosts" "$record_path.known-hosts.original"; fi
if [[ -e "$record_path.known-hosts.$target" ]]; then
    ssh-keygen -F "$MORROWPAL_PUBLIC_IPV4" -f "$record_path.known-hosts.$target" \
        | awk 'NF >= 3 && $1 !~ /^#/ { print $2 " " $3 }' | sort -u >"$work/trusted-keys"
else
    aws ec2 get-console-output --instance-id "$instance" --latest --region "$region" --output json \
        | node "$directory/ssh-host-keys-from-console.mjs" >"$work/trusted-keys"
fi
[[ -s "$work/trusted-keys" ]] || fail 'No trusted host keys available'
# Scanning supplies connectivity/key candidates only. A key must also match the AWS console or preserved original trust.
matched=false
for attempt in {1..30}; do
    ssh-keyscan -T 5 -t ed25519,ecdsa,rsa "$MORROWPAL_PUBLIC_IPV4" >"$work/scanned" 2>/dev/null || true
    awk 'NF >= 3 && $1 !~ /^#/ { print $2 " " $3 }' "$work/scanned" | sort -u >"$work/scanned-keys"
    comm -12 "$work/trusted-keys" "$work/scanned-keys" >"$work/matching-keys"
    if [[ -s "$work/matching-keys" ]]; then matched=true; break; fi
    sleep 2
done
[[ "$matched" == true ]] || fail 'Scanned SSH host keys did not match the trusted source'
cp -- "$known_hosts" "$work/known_hosts"
ssh-keygen -R "$MORROWPAL_PUBLIC_IPV4" -f "$work/known_hosts" >/dev/null 2>&1
awk -v ip="$MORROWPAL_PUBLIC_IPV4" '{ print ip " " $0 }' "$work/matching-keys" >>"$work/known_hosts"
cp "$work/known_hosts" "$known_hosts"
cp "$work/known_hosts" "$record_path.known-hosts.$target"
jq -n --arg host "$MORROWPAL_SSH_HOST_ALIAS" --arg ip "$MORROWPAL_PUBLIC_IPV4" --arg user "$MORROWPAL_SSH_USER" \
    --arg key "$MORROWPAL_SSH_PRIVATE_KEY_FILE" --arg ssh "-o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=yes" '
    {all:{children:{morrowpal_hosts:{hosts:{($host):{ansible_host:$ip,ansible_user:$user,ansible_ssh_private_key_file:$key,ansible_ssh_common_args:$ssh}}}}}}
' >"$work/inventory.json"
# A preserved root can auto-start the application during boot. Quiesce it before
# changing retained-directory ownership or other preparation state.
ansible morrowpal_hosts -i "$work/inventory.json" -e "@$repository/environments/staging/vars.yml" \
    --become -m ansible.builtin.shell --args 'set -eu
if systemctl cat morrowpal.service >/dev/null 2>&1; then
    flock --exclusive --nonblock /run/morrowpal-deploy.lock systemctl stop morrowpal.service
    # Cancelling an in-progress boot startup can leave Result=signal/failed.
    # Clear that state only after the normal stop succeeded.
    systemctl reset-failed morrowpal.service
    test "$(systemctl show morrowpal.service --property ActiveState --value)" = inactive
fi
if command -v docker >/dev/null 2>&1; then
    test -z "$(docker ps -q --filter label=com.docker.compose.project=morrowpal)"
fi'
playbook() { ansible-playbook "$repository/shared/playbooks/$1.yml" -i "$work/inventory.json" -e "@$repository/environments/staging/vars.yml" "${@:2}"; }
for playbook in install-docker install-docker-compose prepare-host prepare-mysql; do playbook "$playbook"; done
jq '{morrowpal_mysql_volume_id:.data.volumeId,morrowpal_require_existing_mysql_filesystem:true,morrowpal_expected_mysql_filesystem_uuid:.data.filesystemUuid}' "$record" >"$work/storage-vars.json"
playbook prepare-storage -e "@$work/storage-vars.json"
playbook prepare-tls -e "morrowpal_certbot_email=$email"
backend="$(jq -r .releases.backend.tag "$record")" app="$(jq -r .releases.app.tag "$record")" website="$(jq -r .releases.website.tag "$record")"
# Deployment obtains its own shared lock and revalidates the live environment bindings.
exec 9>&-
bash "$directory/deploy-images.sh" staging initial "$backend" "$app" "$website"
printf 'Staging %s prepared with verified host trust, retained filesystem and recorded release tags. Verify service behavior, then enable nightly shutdown.\n' "$target"
