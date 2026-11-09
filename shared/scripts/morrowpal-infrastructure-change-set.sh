#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly infrastructure_directory="$(cd -- "$script_directory/../.." && pwd)"
readonly cloudformation_directory="$infrastructure_directory/shared/cloudformation"
readonly cloudformation_environment_template="$infrastructure_directory/shared/runtime/cloudformation.env.j2"

usage() {
    cat <<'EOF'
Usage: morrowpal-infrastructure-change-set.sh ENVIRONMENT STACK_KIND CHANGE_SET_NAME [OPTIONS]

Create one guarded CloudFormation change set for prod or staging.

STACK_KIND:
  prerequisites | ecr | ec2-access | ec2 | mysql-storage | runtime-secrets |
  system-alerts | public-ip | http-validation-ingress

OPTIONS:
  --confirm-production  Required for prod.
  --dry-run             Resolve and validate bindings without creating a change set.
  --detach-mysql-volume Remove the MySQL volume attachment. Valid only for
                        mysql-storage; attachment is the default.
  --ssh-public-key-file PATH
                        Public key to import. Required only for prerequisites.
  --ssh-ingress-cidr CIDR
                        Reviewed IPv4 CIDR for SSH. Required only for prerequisites.

For system-alerts, set MORROWPAL_PRIMARY_ALERT_EMAIL. Optional recipients use
MORROWPAL_SECONDARY_ALERT_EMAIL and MORROWPAL_TERTIARY_ALERT_EMAIL.

The wrapper never executes a change set and accepts no resource-ID overrides.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_ssh_ingress_cidr() {
    local cidr="$1"
    local address
    local octet
    local prefix
    local -a octets=()

    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
        || fail "SSH ingress CIDR must be a valid IPv4 CIDR"
    address="${cidr%/*}"
    prefix="${cidr#*/}"
    IFS='.' read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || fail "SSH ingress CIDR contains an invalid IPv4 address"
    done
    ((10#$prefix > 0)) || fail "SSH ingress CIDR must not allow the entire IPv4 internet"
}

load_ssh_public_key() {
    local key_line
    local key_type
    local key_data
    local ignored_comment
    local -a key_lines=()

    [[ -f "$ssh_public_key_file" ]] \
        || fail "SSH public-key file not found: $ssh_public_key_file"
    if grep -Eq -- 'BEGIN .*PRIVATE KEY|PRIVATE KEY' "$ssh_public_key_file"; then
        fail "SSH public-key file contains private key material"
    fi
    mapfile -t key_lines < <(awk 'NF { print }' "$ssh_public_key_file")
    ((${#key_lines[@]} == 1)) \
        || fail "SSH public-key file must contain exactly one non-empty line"
    key_line="${key_lines[0]}"
    read -r key_type key_data ignored_comment <<<"$key_line"
    [[ "$key_type" == ssh-rsa || "$key_type" == ssh-ed25519 ]] \
        || fail "SSH public key must use ssh-rsa or ssh-ed25519"
    [[ "$key_data" =~ ^[A-Za-z0-9+/=]+$ ]] \
        || fail "SSH public key data is malformed"
    ssh_public_key_material="$key_type $key_data"
}

stack_output() {
    local output_key="$2"
    local stack_json

    stack_json="$(aws cloudformation describe-stacks \
        --stack-name "$1" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Could not read required stack: $1"
    jq --exit-status --raw-output --arg output_key "$output_key" '
        .Stacks[0].Outputs[]
        | select(.OutputKey == $output_key)
        | .OutputValue
    ' <<<"$stack_json" || fail "Stack $1 has no $output_key output"
}

load_environment() {
    local rendered_environment
    local vars_file="$infrastructure_directory/environments/$selected_environment/vars.yml"

    [[ -f "$vars_file" ]] || fail "Environment overlay not found: $vars_file"
    [[ -f "$inventory_file" ]] || fail "Environment inventory not found: $inventory_file"

    rendered_environment="$(mktemp)"
    cleanup_files+=("$rendered_environment")
    ANSIBLE_CONFIG="$infrastructure_directory/ansible.cfg" \
    ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
        ansible localhost \
            -i localhost, \
            --connection local \
            --module-name ansible.builtin.template \
            --args "src=$cloudformation_environment_template dest=$rendered_environment mode=0600" \
            --extra-vars "@$vars_file" >/dev/null \
        || fail "Could not render the $selected_environment CloudFormation configuration"

    set -a
    # shellcheck source=/dev/null
    source "$rendered_environment"
    set +a

    morrowpal_require_environment_values \
        MORROWPAL_ENVIRONMENT \
        MORROWPAL_AWS_ACCOUNT_ID \
        MORROWPAL_AWS_REGION \
        MORROWPAL_AVAILABILITY_ZONE \
        MORROWPAL_STACK_PREFIX \
        MORROWPAL_VPC_ID \
        MORROWPAL_SUBNET_ID \
        MORROWPAL_SECURITY_GROUP_ID \
        MORROWPAL_EC2_KEY_NAME \
        MORROWPAL_INSTANCE_NAME \
        MORROWPAL_INSTANCE_TYPE \
        MORROWPAL_ROOT_VOLUME_SIZE_GIB \
        MORROWPAL_MYSQL_VOLUME_SIZE_GIB \
        MORROWPAL_PUBLIC_IPV4 \
        MORROWPAL_SSH_HOST_ALIAS \
        MORROWPAL_SSH_USER \
        MORROWPAL_SSH_PRIVATE_KEY_FILE \
        MORROWPAL_SSH_KNOWN_HOSTS_FILE

    [[ "$MORROWPAL_ENVIRONMENT" == "$selected_environment" ]] \
        || fail "Overlay environment does not match $selected_environment"
    [[ "$MORROWPAL_STACK_PREFIX" == "morrowpal-$selected_environment" ]] \
        || fail "Stack prefix does not match $selected_environment"
}

validate_inventory() {
    local inventory_json

    inventory_json="$(ANSIBLE_CONFIG="$infrastructure_directory/ansible.cfg" \
        ansible-inventory -i "$inventory_file" --list)" \
        || fail "Could not read the $selected_environment inventory"
    jq --exit-status \
        --arg host "$MORROWPAL_SSH_HOST_ALIAS" \
        --arg public_ip "$MORROWPAL_PUBLIC_IPV4" \
        --arg ssh_user "$MORROWPAL_SSH_USER" \
        --arg private_key "$MORROWPAL_SSH_PRIVATE_KEY_FILE" \
        --arg known_hosts "$MORROWPAL_SSH_KNOWN_HOSTS_FILE" '
        (.morrowpal_hosts.hosts | index($host)) != null
        and ._meta.hostvars[$host].ansible_host == $public_ip
        and ._meta.hostvars[$host].ansible_user == $ssh_user
        and ._meta.hostvars[$host].ansible_ssh_private_key_file == $private_key
        and (._meta.hostvars[$host].ansible_ssh_common_args | contains($known_hosts))
    ' <<<"$inventory_json" >/dev/null \
        || fail "Inventory does not match the selected environment overlay"
}

validate_account_and_region() {
    local active_account
    local configured_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

    if [[ -n "$configured_region" && "$configured_region" != "$MORROWPAL_AWS_REGION" ]]; then
        fail "Configured AWS Region $configured_region does not match $MORROWPAL_AWS_REGION"
    fi
    active_account="$(aws sts get-caller-identity \
        --query Account \
        --output text \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Could not resolve the active AWS account"
    [[ "$active_account" == "$MORROWPAL_AWS_ACCOUNT_ID" ]] \
        || fail "Active AWS account $active_account does not match the selected environment"
}

validate_platform_bindings() {
    local application_tag
    local environment_tag
    local key_pair_json
    local security_group_json
    local subnet_json
    local vpc_json

    vpc_json="$(aws ec2 describe-vpcs \
        --vpc-ids "$MORROWPAL_VPC_ID" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Configured VPC does not exist in the selected account and Region"
    [[ "$(jq --raw-output '.Vpcs[0].VpcId' <<<"$vpc_json")" == "$MORROWPAL_VPC_ID" ]] \
        || fail "Resolved VPC does not match the selected overlay"
    [[ "$(jq --raw-output '.Vpcs[0].OwnerId' <<<"$vpc_json")" == "$MORROWPAL_AWS_ACCOUNT_ID" ]] \
        || fail "Configured VPC belongs to another AWS account"
    [[ "$(jq --raw-output '.Vpcs[0].State' <<<"$vpc_json")" == available ]] \
        || fail "Configured VPC is not available"

    subnet_json="$(aws ec2 describe-subnets \
        --subnet-ids "$MORROWPAL_SUBNET_ID" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Configured subnet does not exist in the selected account and Region"
    [[ "$(jq --raw-output '.Subnets[0].OwnerId' <<<"$subnet_json")" == "$MORROWPAL_AWS_ACCOUNT_ID" ]] \
        || fail "Configured subnet belongs to another AWS account"
    [[ "$(jq --raw-output '.Subnets[0].VpcId' <<<"$subnet_json")" == "$MORROWPAL_VPC_ID" ]] \
        || fail "Configured subnet is not in the approved VPC"
    [[ "$(jq --raw-output '.Subnets[0].AvailabilityZone' <<<"$subnet_json")" == "$MORROWPAL_AVAILABILITY_ZONE" ]] \
        || fail "Configured subnet is not in the approved Availability Zone"
    [[ "$(jq --raw-output '.Subnets[0].State' <<<"$subnet_json")" == available ]] \
        || fail "Configured subnet is not available"

    if [[ "$stack_kind" == prerequisites ]]; then
        return
    fi

    security_group_json="$(aws ec2 describe-security-groups \
        --group-ids "$MORROWPAL_SECURITY_GROUP_ID" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Configured security group does not exist in the selected account and Region"
    [[ "$(jq --raw-output '.SecurityGroups[0].OwnerId' <<<"$security_group_json")" == "$MORROWPAL_AWS_ACCOUNT_ID" ]] \
        || fail "Configured security group belongs to another AWS account"
    [[ "$(jq --raw-output '.SecurityGroups[0].VpcId' <<<"$security_group_json")" == "$MORROWPAL_VPC_ID" ]] \
        || fail "Configured security group is not in the approved VPC"
    environment_tag="$(jq --raw-output '[.SecurityGroups[0].Tags[]? | select(.Key == "Environment")][0].Value // ""' <<<"$security_group_json")"
    application_tag="$(jq --raw-output '[.SecurityGroups[0].Tags[]? | select(.Key == "Application")][0].Value // ""' <<<"$security_group_json")"
    if [[ "$selected_environment" == staging ]]; then
        [[ "$environment_tag" == staging && "$application_tag" == morrowpal ]] \
            || fail "Staging security group is missing its environment identity tags"
    elif [[ -n "$environment_tag" || -n "$application_tag" ]]; then
        [[ "$environment_tag" == prod && "$application_tag" == morrowpal ]] \
            || fail "Production security group has conflicting environment identity tags"
    fi

    key_pair_json="$(aws ec2 describe-key-pairs \
        --key-names "$MORROWPAL_EC2_KEY_NAME" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Configured recovery key pair does not exist in the selected account and Region"
    [[ "$(jq --raw-output '.KeyPairs[0].KeyName' <<<"$key_pair_json")" == "$MORROWPAL_EC2_KEY_NAME" ]] \
        || fail "Resolved recovery key pair does not match the selected overlay"
}

resolve_access_stack() {
    local profile_json

    instance_profile_name="$(stack_output "$MORROWPAL_STACK_PREFIX-ec2-access" InstanceProfileName)"
    instance_profile_arn="$(stack_output "$MORROWPAL_STACK_PREFIX-ec2-access" InstanceProfileArn)"
    role_arn="$(stack_output "$MORROWPAL_STACK_PREFIX-ec2-access" RoleArn)"
    role_name="${role_arn##*/}"
    [[ "$instance_profile_arn" == "arn:"*:"iam::$MORROWPAL_AWS_ACCOUNT_ID:instance-profile/$instance_profile_name" ]] \
        || fail "EC2 access outputs do not belong to the selected AWS account"
    [[ "$role_arn" == "arn:"*:"iam::$MORROWPAL_AWS_ACCOUNT_ID:role/$role_name" ]] \
        || fail "EC2 role output does not belong to the selected AWS account"

    profile_json="$(aws iam get-instance-profile \
        --instance-profile-name "$instance_profile_name" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Could not validate the selected EC2 instance profile"
    [[ "$(jq --raw-output '.InstanceProfile.Arn' <<<"$profile_json")" == "$instance_profile_arn" ]] \
        || fail "Resolved instance-profile ARN does not match the access stack output"
    [[ "$(jq --raw-output '.InstanceProfile.Roles[0].RoleName' <<<"$profile_json")" == "$role_name" ]] \
        || fail "Resolved EC2 role does not match the selected instance profile"
}

resolve_and_validate_instance() {
    local instance_json

    instance_id="$(stack_output "$MORROWPAL_STACK_PREFIX-ec2" InstanceId)"
    instance_availability_zone="$(stack_output "$MORROWPAL_STACK_PREFIX-ec2" AvailabilityZone)"
    instance_json="$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --output json \
        --region "$MORROWPAL_AWS_REGION")" \
        || fail "Could not validate the selected EC2 instance"

    jq --exit-status \
        --arg environment "$selected_environment" \
        --arg instance_name "$MORROWPAL_INSTANCE_NAME" \
        --arg stack_name "$MORROWPAL_STACK_PREFIX-ec2" \
        --arg subnet_id "$MORROWPAL_SUBNET_ID" \
        --arg security_group_id "$MORROWPAL_SECURITY_GROUP_ID" \
        --arg availability_zone "$instance_availability_zone" \
        --arg profile_arn "$instance_profile_arn" '
        .Reservations[0].Instances[0] as $instance
        | $instance.SubnetId == $subnet_id
          and $instance.Placement.AvailabilityZone == $availability_zone
          and $instance.IamInstanceProfile.Arn == $profile_arn
          and ([$instance.SecurityGroups[].GroupId] | index($security_group_id)) != null
          and ([$instance.Tags[] | select(.Key == "Application")][0].Value // "") == "morrowpal"
          and ([$instance.Tags[] | select(.Key == "Environment")][0].Value // "") == $environment
          and ([$instance.Tags[] | select(.Key == "Name")][0].Value // "") == $instance_name
          and ([$instance.Tags[] | select(.Key == "aws:cloudformation:stack-name")][0].Value // "") == $stack_name
          and $instance.State.Name != "terminated"
    ' <<<"$instance_json" >/dev/null \
        || fail "EC2 instance does not match the selected environment bindings"
    [[ "$instance_availability_zone" == "$MORROWPAL_AVAILABILITY_ZONE" ]] \
        || fail "EC2 stack Availability Zone does not match the selected overlay"
}

resolve_target_change_type() {
    local describe_error_file
    local describe_output_file

    describe_output_file="$(mktemp)"
    describe_error_file="$(mktemp)"
    cleanup_files+=("$describe_output_file" "$describe_error_file")
    if aws cloudformation describe-stacks \
            --stack-name "$target_stack_name" \
            --output json \
            --region "$MORROWPAL_AWS_REGION" \
            >"$describe_output_file" 2>"$describe_error_file"; then
        change_set_type=UPDATE
    elif grep -Eqi 'does not exist|not exist' "$describe_error_file"; then
        change_set_type=CREATE
    else
        fail "Could not determine whether target stack $target_stack_name exists"
    fi
}

build_parameters() {
    parameters=("ParameterKey=Environment,ParameterValue=$selected_environment")
    capabilities=()

    case "$stack_kind" in
        prerequisites)
            parameters+=(
                "ParameterKey=VpcId,ParameterValue=$MORROWPAL_VPC_ID"
                "ParameterKey=KeyName,ParameterValue=$MORROWPAL_EC2_KEY_NAME"
                "ParameterKey=SshPublicKeyMaterial,ParameterValue=$ssh_public_key_material"
                "ParameterKey=SshIngressCidr,ParameterValue=$ssh_ingress_cidr"
            )
            ;;
        ecr)
            ;;
        ec2-access)
            capabilities=(CAPABILITY_IAM)
            ;;
        ec2)
            parameters+=(
                "ParameterKey=InstanceType,ParameterValue=$MORROWPAL_INSTANCE_TYPE"
                "ParameterKey=KeyName,ParameterValue=$MORROWPAL_EC2_KEY_NAME"
                "ParameterKey=SubnetId,ParameterValue=$MORROWPAL_SUBNET_ID"
                "ParameterKey=SecurityGroupId,ParameterValue=$MORROWPAL_SECURITY_GROUP_ID"
                "ParameterKey=InstanceProfileName,ParameterValue=$instance_profile_name"
                "ParameterKey=RootVolumeSizeGiB,ParameterValue=$MORROWPAL_ROOT_VOLUME_SIZE_GIB"
            )
            ;;
        mysql-storage)
            local attach_volume=true
            if [[ "$detach_mysql_volume" == true ]]; then
                attach_volume=false
            fi
            parameters+=(
                "ParameterKey=AvailabilityZone,ParameterValue=$instance_availability_zone"
                "ParameterKey=InstanceId,ParameterValue=$instance_id"
                "ParameterKey=AttachVolume,ParameterValue=$attach_volume"
                "ParameterKey=VolumeSizeGiB,ParameterValue=$MORROWPAL_MYSQL_VOLUME_SIZE_GIB"
            )
            ;;
        runtime-secrets)
            parameters+=("ParameterKey=Ec2RoleName,ParameterValue=$role_name")
            capabilities=(CAPABILITY_IAM)
            ;;
        system-alerts)
            [[ -n "${MORROWPAL_PRIMARY_ALERT_EMAIL:-}" ]] \
                || fail "MORROWPAL_PRIMARY_ALERT_EMAIL is required for system-alerts"
            parameters+=(
                "ParameterKey=Ec2RoleName,ParameterValue=$role_name"
                "ParameterKey=PrimaryAlertEmail,ParameterValue=$MORROWPAL_PRIMARY_ALERT_EMAIL"
                "ParameterKey=SecondaryAlertEmail,ParameterValue=${MORROWPAL_SECONDARY_ALERT_EMAIL:-}"
                "ParameterKey=TertiaryAlertEmail,ParameterValue=${MORROWPAL_TERTIARY_ALERT_EMAIL:-}"
            )
            capabilities=(CAPABILITY_IAM)
            ;;
        public-ip)
            parameters+=("ParameterKey=InstanceId,ParameterValue=$instance_id")
            ;;
        http-validation-ingress)
            parameters=("ParameterKey=SecurityGroupId,ParameterValue=$MORROWPAL_SECURITY_GROUP_ID")
            ;;
    esac
}

print_resolution() {
    printf 'Environment: %s\n' "$selected_environment"
    printf 'AWS account: %s\n' "$MORROWPAL_AWS_ACCOUNT_ID"
    printf 'AWS Region: %s\n' "$MORROWPAL_AWS_REGION"
    printf 'Stack: %s\n' "$target_stack_name"
    printf 'Change-set type: %s\n' "$change_set_type"
    printf 'Template: %s\n' "${template_path#$infrastructure_directory/}"
    printf 'Subnet: %s\n' "$MORROWPAL_SUBNET_ID"
    if [[ "$stack_kind" == prerequisites ]]; then
        printf 'Recovery key pair: %s\n' "$MORROWPAL_EC2_KEY_NAME"
        printf 'SSH ingress CIDR: %s\n' "$ssh_ingress_cidr"
        printf 'SSH public key: validated; material hidden\n'
    else
        printf 'Security group: %s\n' "$MORROWPAL_SECURITY_GROUP_ID"
    fi
    if [[ -n "$instance_profile_name" ]]; then
        printf 'Instance profile: %s\n' "$instance_profile_name"
        printf 'EC2 role: %s\n' "$role_name"
    fi
    if [[ -n "$instance_id" ]]; then
        printf 'EC2 instance: %s\n' "$instance_id"
    fi
    if [[ "$stack_kind" == mysql-storage ]]; then
        if [[ "$detach_mysql_volume" == true ]]; then
            printf 'MySQL volume attachment: detached\n'
        else
            printf 'MySQL volume attachment: attached\n'
        fi
    fi
}

cleanup() {
    if ((${#cleanup_files[@]} > 0)); then
        rm -f -- "${cleanup_files[@]}"
    fi
}

if (($# < 3)); then
    usage >&2
    exit 2
fi

readonly selected_environment="$1"
readonly stack_kind="$2"
readonly change_set_name="$3"
shift 3

case "$selected_environment" in
    prod|staging) ;;
    *) fail "ENVIRONMENT must be prod or staging" ;;
esac
case "$stack_kind" in
    prerequisites|ecr|ec2-access|ec2|mysql-storage|runtime-secrets|system-alerts|public-ip|http-validation-ingress) ;;
    *) fail "Unknown STACK_KIND: $stack_kind" ;;
esac
[[ "$change_set_name" =~ ^[A-Za-z][A-Za-z0-9-]{0,127}$ ]] \
    || fail "CHANGE_SET_NAME must start with a letter and contain only letters, digits, and hyphens"

confirm_production=false
dry_run=false
detach_mysql_volume=false
ssh_public_key_file=''
ssh_ingress_cidr=''
while (($# > 0)); do
    case "$1" in
        --confirm-production)
            confirm_production=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --detach-mysql-volume)
            detach_mysql_volume=true
            shift
            ;;
        --ssh-public-key-file)
            (($# >= 2)) || fail "--ssh-public-key-file requires a path"
            [[ -z "$ssh_public_key_file" ]] || fail "--ssh-public-key-file may be provided only once"
            ssh_public_key_file="$2"
            shift 2
            ;;
        --ssh-ingress-cidr)
            (($# >= 2)) || fail "--ssh-ingress-cidr requires a CIDR"
            [[ -z "$ssh_ingress_cidr" ]] || fail "--ssh-ingress-cidr may be provided only once"
            ssh_ingress_cidr="$2"
            shift 2
            ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ "$selected_environment" == prod && "$confirm_production" != true ]]; then
    fail "Production change-set creation requires --confirm-production"
fi
if [[ "$selected_environment" == staging && "$confirm_production" == true ]]; then
    fail "--confirm-production cannot be used with staging"
fi
if [[ "$detach_mysql_volume" == true && "$stack_kind" != mysql-storage ]]; then
    fail "--detach-mysql-volume is valid only for mysql-storage"
fi
if [[ "$stack_kind" == prerequisites ]]; then
    [[ -n "$ssh_public_key_file" ]] \
        || fail "--ssh-public-key-file is required for prerequisites"
    [[ -n "$ssh_ingress_cidr" ]] \
        || fail "--ssh-ingress-cidr is required for prerequisites"
    validate_ssh_ingress_cidr "$ssh_ingress_cidr"
    load_ssh_public_key
elif [[ -n "$ssh_public_key_file" || -n "$ssh_ingress_cidr" ]]; then
    fail "SSH bootstrap options are valid only for prerequisites"
fi

readonly inventory_file="$infrastructure_directory/environments/$selected_environment/inventory.ini"
readonly target_stack_name="morrowpal-$selected_environment-$stack_kind"
readonly template_path="$cloudformation_directory/$stack_kind.yml"
readonly change_set_name
readonly target_stack_name
readonly template_path

declare -a cleanup_files=()
declare -a parameters=()
declare -a capabilities=()
instance_profile_name=''
instance_profile_arn=''
role_arn=''
role_name=''
instance_id=''
instance_availability_zone=''
change_set_type=''
trap cleanup EXIT

# shellcheck source=morrowpal-runtime-config.sh
source "$script_directory/morrowpal-runtime-config.sh"

require_command ansible
require_command ansible-inventory
require_command aws
require_command jq
[[ -f "$template_path" ]] || fail "CloudFormation template not found: $template_path"

load_environment
validate_inventory
validate_account_and_region
validate_platform_bindings
resolve_target_change_type

case "$stack_kind" in
    prerequisites|ecr|ec2-access)
        ;;
    ec2)
        resolve_access_stack
        if [[ "$change_set_type" == UPDATE ]]; then
            resolve_and_validate_instance
        fi
        ;;
    *)
        resolve_access_stack
        resolve_and_validate_instance
        ;;
esac

build_parameters
print_resolution

if [[ "$dry_run" == true ]]; then
    printf 'Dry run: validation passed; no change set was created.\n'
    exit 0
fi

create_change_set=(
    aws cloudformation create-change-set
    --stack-name "$target_stack_name"
    --change-set-name "$change_set_name"
    --change-set-type "$change_set_type"
    --template-body "file://$template_path"
    --parameters "${parameters[@]}"
    --region "$MORROWPAL_AWS_REGION"
)
if ((${#capabilities[@]} > 0)); then
    create_change_set+=(--capabilities "${capabilities[@]}")
fi
"${create_change_set[@]}"
printf 'Created change set %s for %s; review it before explicit execution.\n' \
    "$change_set_name" "$target_stack_name"
