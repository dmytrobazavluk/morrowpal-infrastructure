#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
infrastructure_directory="$(cd -- "$script_directory/../.." && pwd)"

load_deployment_environment() {
    local selected_environment="$1"
    local repository_directory="$2"
    local environment_file
    local expected_registry variable

    case "$selected_environment" in
        prod|staging)
            ;;
        *)
            printf 'Environment must be prod or staging.\n' >&2
            return 1
            ;;
    esac

    command -v ansible >/dev/null 2>&1 || {
        printf 'Required command not found: ansible\n' >&2
        return 1
    }

    environment_file="$work_directory/runtime.env"
    if ! ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
        ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
            ansible localhost \
                -i localhost, \
                --connection local \
                --module-name ansible.builtin.template \
                --args "src=$repository_directory/shared/runtime/compose.env.j2 dest=$environment_file mode=0600" \
                --extra-vars "@$work_directory/vars.yml" >/dev/null; then
        rm -f -- "$environment_file"
        return 1
    fi

    set -a
    # shellcheck source=/dev/null
    source "$environment_file"
    set +a
    rm -f -- "$environment_file"

    for variable in MORROWPAL_AWS_ACCOUNT_ID MORROWPAL_AWS_REGION \
        MORROWPAL_ECR_REGISTRY MORROWPAL_ECR_REPOSITORY_PREFIX; do
        [[ -n "${!variable:-}" ]] || {
            printf 'Required environment value is missing: %s\n' "$variable" >&2
            return 1
        }
    done

    expected_registry="${MORROWPAL_AWS_ACCOUNT_ID}.dkr.ecr.${MORROWPAL_AWS_REGION}.amazonaws.com"
    [[ "$MORROWPAL_ECR_REGISTRY" == "$expected_registry" ]] || {
        printf 'Configured ECR registry does not match the selected account and Region.\n' >&2
        return 1
    }
}

usage() {
    cat <<'EOF'
Usage: deploy-images.sh ENVIRONMENT COMPONENT [IMAGE_TAG] [OPTIONS]

Validate the target, publish release images, and deploy through Ansible.
ENVIRONMENT is staging or prod. COMPONENT is backend, app, website, or infrastructure.
Backend publishes API and job images together. Infrastructure keeps the host's
recorded image tags. Production requires --confirm-production.

OPTIONS:
  --dry-run             Validate bindings and image sources; print the plan.
  --check               Preview Ansible changes using already-published images.
  --diff                Include configuration differences with --check.
  --confirm-production  Required for prod.
  --frontend-directory PATH  Location of the frontend checkout.

Example: shared/scripts/deploy-images.sh staging app "$APP_TAG"
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if (($# == 1)) && [[ "$1" == -h || "$1" == --help ]]; then usage; exit 0; fi
if (($# < 2)); then usage >&2; exit 2; fi
readonly environment="$1" component="$2"
shift 2
image_tag=""
if [[ "$component" != infrastructure ]]; then
    (($# >= 1)) || fail "IMAGE_TAG is required"
    image_tag="$1"; shift
fi
confirm_production=false
dry_run=false
check_mode=false
diff_mode=false
frontend_directory=""
while (($#)); do
    case "$1" in
        --confirm-production) confirm_production=true ;;
        --dry-run) dry_run=true ;;
        --check) check_mode=true ;;
        --diff) diff_mode=true ;;
        --frontend-directory)
            (($# >= 2)) || fail "--frontend-directory requires a path"
            frontend_directory="$(cd -- "$2" && pwd)" || fail "Frontend directory does not exist"
            shift ;;
        *) fail "Unknown argument: $1" ;;
    esac
    shift
done
[[ "$dry_run" == false || "$check_mode" == false ]] || fail "Choose --dry-run or --check"
[[ "$diff_mode" == false || "$check_mode" == true ]] || fail "--diff requires --check"
case "$environment" in
    staging) [[ "$confirm_production" == false ]] || fail 'Production confirmation cannot be used with staging' ;;
    prod) [[ "$confirm_production" == true ]] || fail 'Production deployment requires --confirm-production' ;;
    *) fail 'Environment must be staging or prod' ;;
esac
case "$component" in
    backend) repositories=(backend-api backend-job) ;;
    app|website) repositories=("$component") ;;
    infrastructure) repositories=() ;;
    *) fail 'Component must be backend, app, website, or infrastructure' ;;
esac
[[ "$component" == infrastructure || "$image_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || fail 'IMAGE_TAG must use build-N-SOURCEHASH'
for command in aws jq ansible ansible-inventory ansible-playbook; do
    command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

umask 077
work_directory="$(mktemp -d)"
trap 'rm -rf -- "$work_directory"' EXIT
docker_auth_directory="$work_directory/docker"
mkdir "$docker_auth_directory"
cd "$infrastructure_directory"
export ANSIBLE_CONFIG="$infrastructure_directory/ansible.cfg"
export ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote
for variable in ANSIBLE_INVENTORY ANSIBLE_PRIVATE_KEY_FILE ANSIBLE_REMOTE_USER \
    ANSIBLE_CONNECTION ANSIBLE_SSH_ARGS ANSIBLE_SSH_COMMON_ARGS ANSIBLE_SSH_EXTRA_ARGS; do
    [[ -z "${!variable:-}" ]] || fail "Unset $variable; deployment selects the connection settings"
done

# Snapshot reviewed inputs so validation and deployment use the same files.
cp "environments/$environment/vars.yml" "$work_directory/vars.yml"
load_deployment_environment "$environment" "$infrastructure_directory"
ansible localhost -i localhost, --connection local --module-name ansible.builtin.template \
    --args "src=$infrastructure_directory/shared/runtime/cloudformation.env.j2 dest=$work_directory/identity.env mode=0600" \
    --extra-vars "@$work_directory/vars.yml" >/dev/null
source "$work_directory/identity.env"
[[ "$MORROWPAL_ENVIRONMENT" == "$environment" && "$MORROWPAL_STACK_PREFIX" == "morrowpal-$environment" ]] \
    || fail 'Overlay environment or stack prefix does not match the selected environment'
[[ "$MORROWPAL_ECR_REPOSITORY_PREFIX" == "morrowpal/$environment" \
    && "$MORROWPAL_SECRETS_PREFIX" == "morrowpal/$environment" ]] \
    || fail 'Overlay resource paths do not match the selected environment'
[[ "$MORROWPAL_SYSTEM_ALERTS_TOPIC_ARN" == "arn:aws:sns:$MORROWPAL_AWS_REGION:$MORROWPAL_AWS_ACCOUNT_ID:morrowpal-$environment-system-alerts" ]] \
    || fail 'Overlay alert topic does not match the selected environment'
for variable in AWS_REGION AWS_DEFAULT_REGION; do
    [[ -z "${!variable:-}" || "${!variable}" == "$MORROWPAL_AWS_REGION" ]] \
        || fail "Configured $variable does not match the selected Region"
done
[[ "${MORROWPAL_SSH_PRIVATE_KEY_FILE##*/}" == "morrowpal-$environment-01.pem" ]] \
    || fail 'Recovery key path does not match the selected environment'
[[ -f "$MORROWPAL_SSH_PRIVATE_KEY_FILE" ]] || fail 'Selected SSH private key file is missing'

inventory_file="environments/$environment/inventory.ini"
ansible-inventory -i "$inventory_file" --list >"$work_directory/inventory-source.json"
expected_ssh_args="-o UserKnownHostsFile=$MORROWPAL_SSH_KNOWN_HOSTS_FILE -o StrictHostKeyChecking=accept-new"
jq --exit-status --arg host "$MORROWPAL_SSH_HOST_ALIAS" --arg ip "$MORROWPAL_PUBLIC_IPV4" \
    --arg user "$MORROWPAL_SSH_USER" --arg key "$MORROWPAL_SSH_PRIVATE_KEY_FILE" \
    --arg ssh_args "$expected_ssh_args" '
    .morrowpal_hosts.hosts == [$host]
    and (._meta.hostvars | keys) == [$host]
    and (._meta.hostvars[$host] | keys) == ["ansible_host", "ansible_ssh_common_args", "ansible_ssh_private_key_file", "ansible_user"]
    and ._meta.hostvars[$host].ansible_host == $ip
    and ._meta.hostvars[$host].ansible_user == $user
    and ._meta.hostvars[$host].ansible_ssh_private_key_file == $key
    and ._meta.hostvars[$host].ansible_ssh_common_args == $ssh_args
' "$work_directory/inventory-source.json" >/dev/null || fail 'Inventory does not match the selected overlay'
jq --arg host "$MORROWPAL_SSH_HOST_ALIAS" '
    {all: {children: {morrowpal_hosts: {hosts: {($host): ._meta.hostvars[$host]}}}}}
' "$work_directory/inventory-source.json" >"$work_directory/inventory.json"
readonly aws_region="$MORROWPAL_AWS_REGION" registry="$MORROWPAL_ECR_REGISTRY"
actual_account="$(aws sts get-caller-identity --query Account --output text --region "$aws_region")"
[[ "$actual_account" == "$MORROWPAL_AWS_ACCOUNT_ID" ]] || fail 'AWS account does not match the selected environment'

stack_output() {
    jq --exit-status --raw-output --arg key "$2" \
        '.Stacks[0].Outputs[] | select(.OutputKey == $key) | .OutputValue | select(length > 0)' "$1" \
        || fail "Missing $2 output in the selected stack"
}
validate_target() {
    for kind in ec2 ec2-access public-ip; do
        stack_name="$MORROWPAL_STACK_PREFIX-$kind"
        aws cloudformation describe-stacks --stack-name "$stack_name" --region "$aws_region" \
            --output json >"$work_directory/$kind.json"
        jq --exit-status --arg prefix "arn:aws:cloudformation:$aws_region:$actual_account:stack/$stack_name/" '
            (.Stacks | length) == 1
            and (.Stacks[0].StackId | startswith($prefix))
            and (.Stacks[0].StackStatus | IN("CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"))
        ' "$work_directory/$kind.json" >/dev/null || fail 'Stack identity or state does not match the deployment'
    done
    instance_id="$(stack_output "$work_directory/ec2.json" InstanceId)"
    profile_arn="$(stack_output "$work_directory/ec2-access.json" InstanceProfileArn)"
    role_arn="$(stack_output "$work_directory/ec2-access.json" RoleArn)"
    allocation_id="$(stack_output "$work_directory/public-ip.json" AllocationId)"
    [[ "$(stack_output "$work_directory/ec2.json" AvailabilityZone)" == "$MORROWPAL_AVAILABILITY_ZONE" ]] \
        || fail 'Instance stack Availability Zone does not match the overlay'
    [[ "$(stack_output "$work_directory/public-ip.json" PublicIp)" == "$MORROWPAL_PUBLIC_IPV4" ]] \
        || fail 'Public IP stack does not match the overlay'
    [[ "$profile_arn" == "arn:aws:iam::$actual_account:instance-profile/"* \
        && "$role_arn" == "arn:aws:iam::$actual_account:role/"* ]] || fail 'Instance profile or role belongs to another account'
    aws iam get-instance-profile --instance-profile-name "${profile_arn##*/}" --region "$aws_region" \
        --output json >"$work_directory/profile.json"
    jq --exit-status --arg profile "$profile_arn" --arg role "$role_arn" '
        .InstanceProfile.Arn == $profile and [.InstanceProfile.Roles[].Arn] == [$role]
    ' "$work_directory/profile.json" >/dev/null || fail 'Instance role does not match the access stack'
    aws ec2 describe-instances --instance-ids "$instance_id" --region "$aws_region" \
        --output json >"$work_directory/instance.json"
    jq --exit-status --arg id "$instance_id" --arg environment "$environment" --arg account "$actual_account" \
        --arg name "$MORROWPAL_INSTANCE_NAME" --arg stack "$MORROWPAL_STACK_PREFIX-ec2" \
        --arg ip "$MORROWPAL_PUBLIC_IPV4" --arg vpc "$MORROWPAL_VPC_ID" --arg subnet "$MORROWPAL_SUBNET_ID" \
        --arg group "$MORROWPAL_SECURITY_GROUP_ID" --arg zone "$MORROWPAL_AVAILABILITY_ZONE" \
        --arg key "$MORROWPAL_EC2_KEY_NAME" --arg profile "$profile_arn" '
        (.Reservations | length) == 1 and .Reservations[0].OwnerId == $account
        and (.Reservations[0].Instances | length) == 1
        and (.Reservations[0].Instances[0] | . as $instance
            | .InstanceId == $id and .State.Name == "running"
            and .PublicIpAddress == $ip and .VpcId == $vpc and .SubnetId == $subnet
            and [.SecurityGroups[].GroupId] == [$group] and .Placement.AvailabilityZone == $zone
            and .KeyName == $key and .IamInstanceProfile.Arn == $profile
            and ([.Tags[] | select(.Key == "Environment")][0].Value == $environment)
            and ([.Tags[] | select(.Key == "Application")][0].Value == "morrowpal")
            and ([.Tags[] | select(.Key == "Name")][0].Value == $name)
            and ([.Tags[] | select(.Key == "aws:cloudformation:stack-name")][0].Value == $stack))
    ' "$work_directory/instance.json" >/dev/null || fail 'Instance does not match the selected environment bindings'
    aws ec2 describe-addresses --allocation-ids "$allocation_id" --region "$aws_region" \
        --output json >"$work_directory/address.json"
    jq --exit-status --arg ip "$MORROWPAL_PUBLIC_IPV4" --arg id "$instance_id" --arg allocation "$allocation_id" '
        (.Addresses | length) == 1 and .Addresses[0].PublicIp == $ip
        and .Addresses[0].InstanceId == $id and .Addresses[0].AllocationId == $allocation
    ' "$work_directory/address.json" >/dev/null || fail 'Elastic IP is not associated with the selected instance'
    printf 'Validated %s: account %s, Region %s, instance %s, IP %s.\n' \
        "$environment" "$actual_account" "$aws_region" "$instance_id" "$MORROWPAL_PUBLIC_IPV4"
}
validate_target
readonly validated_instance_id="$instance_id" validated_profile="$profile_arn" \
    validated_role="$role_arn" validated_allocation="$allocation_id"

local_ids=()
known_digests=()
remote_digests=()
publish_image=()
for repository in "${repositories[@]}"; do
    command -v docker >/dev/null 2>&1 || fail 'Required command not found: docker'
    target_repository="$MORROWPAL_ECR_REPOSITORY_PREFIX/$repository"
    mutability="$(aws ecr describe-repositories --registry-id "$actual_account" \
        --repository-names "$target_repository" --query 'repositories[0].imageTagMutability' \
        --output text --region "$aws_region")"
    [[ "$mutability" == IMMUTABLE ]] || fail 'Release repositories must use immutable tags'
    local_id="$(docker image inspect --format '{{.Id}}' "morrowpal/$repository:$image_tag" 2>/dev/null)" || local_id=""
    local_ids+=("$local_id")
    known_digest=""
    if [[ -n "$local_id" ]]; then
        known_digest="$(docker image inspect --format '{{json .RepoDigests}}' "$local_id" \
            | jq -r '.[0] // "" | split("@") | .[1] // ""')"
    fi
    known_digests+=("$known_digest")
    if remote_digest="$(aws ecr describe-images --registry-id "$actual_account" \
        --repository-name "$target_repository" --image-ids "imageTag=$image_tag" \
        --query 'imageDetails[0].imageDigest' --output text --region "$aws_region" \
        2>"$work_directory/image-error")"; then
        [[ "$remote_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Published image digest is missing'
        if [[ -n "$local_id" ]]; then
            [[ "$known_digest" == "$remote_digest" ]] \
                || fail 'Published tag does not match the known local image digest'
        fi
        publish_image+=(false)
    elif grep -Fq ImageNotFoundException "$work_directory/image-error"; then
        [[ -n "$local_id" ]] || fail "Image is missing locally and in $environment ECR: $repository:$image_tag"
        [[ "$check_mode" == false ]] || fail '--check requires already-published images; use --dry-run to preview a new release'
        remote_digest=""
        publish_image+=(true)
    else
        cat "$work_directory/image-error" >&2
        fail "Could not inspect $target_repository:$image_tag"
    fi
    remote_digests+=("$remote_digest")
    printf 'Image: %s/%s:%s; publish=%s; digest=%s\n' "$registry" "$target_repository" \
        "$image_tag" "${publish_image[-1]}" "${remote_digest:-pending}"
done

case "$component" in
    backend) tag_variable=morrowpal_image_tag ;;
    app) tag_variable=morrowpal_app_image_tag ;;
    website) tag_variable=morrowpal_website_image_tag ;;
    infrastructure) tag_variable="" ;;
esac
jq -n --arg variable "$tag_variable" --arg tag "$image_tag" --arg frontend "$frontend_directory" '
    (if $variable == "" then {} else {($variable): $tag} end)
    + (if $frontend == "" then {} else {morrowpal_frontend_directory: $frontend} end)
    + {ansible_connection: "ssh", ansible_port: 22}
' >"$work_directory/release.json"
deploy_command=(ansible-playbook "$infrastructure_directory/shared/playbooks/deploy.yml"
    --inventory "$work_directory/inventory.json" --limit "$MORROWPAL_SSH_HOST_ALIAS"
    --extra-vars "@$work_directory/vars.yml" --extra-vars "@$work_directory/release.json")
if [[ "$check_mode" == true ]]; then deploy_command+=(--check); fi
if [[ "$diff_mode" == true ]]; then deploy_command+=(--diff); fi
printf 'Deployment: %s using %s and environments/%s/vars.yml.\n' "$component" "$inventory_file" "$environment"
if [[ "$dry_run" == true ]]; then
    printf 'Dry run complete; no registry writes or remote host connection.\n'
    exit 0
fi

wait_for_scan() {
    local repository="$1" result status critical high attempt
    for ((attempt=1; attempt<=30; attempt++)); do
        if result="$(aws ecr describe-image-scan-findings \
            --repository-name "$repository" --image-id "imageTag=$image_tag" \
            --query '{status:imageScanStatus.status,findings:imageScanFindings.findingSeverityCounts}' \
            --output json --region "$aws_region" 2>"$docker_auth_directory/scan-error")"; then
            status="$(jq -r .status <<<"$result")"
            case "$status" in
                COMPLETE)
                    printf '%s\n' "$result"
                    critical="$(jq -r '.findings.CRITICAL // 0' <<<"$result")"
                    high="$(jq -r '.findings.HIGH // 0' <<<"$result")"
                    ((critical == 0 && high == 0)) || fail "$repository has critical or high findings"
                    return 0 ;;
                IN_PROGRESS|PENDING) ;;
                *) fail "Image scan for $repository ended with status $status" ;;
            esac
        elif ! grep -Fq ScanNotFoundException "$docker_auth_directory/scan-error"; then
            cat "$docker_auth_directory/scan-error" >&2
            fail "Could not check scan for $repository"
        fi
        printf 'Waiting for scan of %s:%s (%s/30)...\n' "$repository" "$image_tag" "$attempt"
        if ((attempt < 30)); then sleep 10; fi
    done
    fail "Timed out waiting for scan of $repository:$image_tag"
}

logged_in=false
for index in "${!repositories[@]}"; do
    repository="$MORROWPAL_ECR_REPOSITORY_PREFIX/${repositories[$index]}"
    if [[ "${publish_image[$index]}" == true ]]; then
        if [[ "$logged_in" == false ]]; then
            aws ecr get-login-password --region "$aws_region" \
                | docker --config "$docker_auth_directory" login --username AWS --password-stdin "$registry"
            logged_in=true
        fi
        target="$registry/$repository:$image_tag"
        docker tag "${local_ids[$index]}" "$target"
        docker --config "$docker_auth_directory" push "$target"
        remote_digest="$(aws ecr describe-images --registry-id "$actual_account" \
            --repository-name "$repository" --image-ids "imageTag=$image_tag" \
            --query 'imageDetails[0].imageDigest' --output text --region "$aws_region")"
        [[ "$remote_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Missing remote digest for $target"
        docker image inspect --format '{{json .RepoDigests}}' "${local_ids[$index]}" \
            | jq --exit-status --arg ref "$registry/$repository@$remote_digest" 'index($ref) != null' >/dev/null \
            || fail "Remote digest does not match the pushed local image: $target"
        [[ -z "${known_digests[$index]}" || "${known_digests[$index]}" == "$remote_digest" ]] \
            || fail "Manifest digest differs from the previously pushed image: $target"
        remote_digests[$index]="$remote_digest"
    fi
    wait_for_scan "$repository"
done

# All images must pass publication and scanning before the first host action.
# Recheck AWS bindings after scanning, which can take several minutes.
validate_target
[[ "$instance_id" == "$validated_instance_id" && "$profile_arn" == "$validated_profile" \
    && "$role_arn" == "$validated_role" && "$allocation_id" == "$validated_allocation" ]] \
    || fail 'Deployment target changed during publication; review and retry'
printf 'Running %s deployment on validated instance %s.\n' "$component" "$instance_id"
"${deploy_command[@]}"
printf 'Deployment verified by the shared playbook: %s %s %s.\n' "$environment" "$component" "$image_tag"
