#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly wrapper="$script_directory/morrowpal-infrastructure-change-set.sh"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

install_mock_ansible() {
    local mock_directory="$1"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'joined="$*"' \
        '[[ "$joined" =~ dest=([^[:space:]]+) ]] || exit 2' \
        'destination="${BASH_REMATCH[1]}"' \
        'if [[ "$joined" == *environments/prod/vars.yml* ]]; then' \
        '  environment=prod' \
        '  public_ip=3.12.65.199' \
        '  private_key=../morrowpal-prod-01.pem' \
        '  known_hosts=environments/prod/known_hosts' \
        '  vpc_id=vpc-prod' \
        '  subnet_id=subnet-prod' \
        '  security_group_id=sg-prod' \
        '  key_name=01' \
        'else' \
        '  environment=staging' \
        '  public_ip=STAGING_PUBLIC_IP' \
        '  private_key=../morrowpal-staging-01.pem' \
        '  known_hosts=environments/staging/known_hosts' \
        '  vpc_id=vpc-staging' \
        '  subnet_id=subnet-staging' \
        '  security_group_id=sg-staging' \
        '  key_name=morrowpal-staging-01' \
        'fi' \
        'overlay_environment="$environment"' \
        'stack_prefix="morrowpal-$environment"' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == overlay ]]; then overlay_environment=prod; fi' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == prefix ]]; then stack_prefix=morrowpal-wrong; fi' \
        'printf "%s\n" \' \
        '  "MORROWPAL_ENVIRONMENT=\"$overlay_environment\"" \' \
        '  "MORROWPAL_AWS_ACCOUNT_ID=\"384078510608\"" \' \
        '  "MORROWPAL_AWS_REGION=\"us-east-2\"" \' \
        '  "MORROWPAL_AVAILABILITY_ZONE=\"us-east-2c\"" \' \
        '  "MORROWPAL_STACK_PREFIX=\"$stack_prefix\"" \' \
        '  "MORROWPAL_VPC_ID=\"$vpc_id\"" \' \
        '  "MORROWPAL_SUBNET_ID=\"$subnet_id\"" \' \
        '  "MORROWPAL_SECURITY_GROUP_ID=\"$security_group_id\"" \' \
        '  "MORROWPAL_EC2_KEY_NAME=\"$key_name\"" \' \
        '  "MORROWPAL_INSTANCE_NAME=\"morrowpal-$environment-01\"" \' \
        '  "MORROWPAL_INSTANCE_TYPE=\"t3.small\"" \' \
        '  "MORROWPAL_ROOT_VOLUME_SIZE_GIB=8" \' \
        '  "MORROWPAL_MYSQL_VOLUME_SIZE_GIB=10" \' \
        '  "MORROWPAL_PUBLIC_IPV4=\"$public_ip\"" \' \
        '  "MORROWPAL_SSH_HOST_ALIAS=\"01\"" \' \
        '  "MORROWPAL_SSH_USER=\"ec2-user\"" \' \
        '  "MORROWPAL_SSH_PRIVATE_KEY_FILE=\"$private_key\"" \' \
        '  "MORROWPAL_SSH_KNOWN_HOSTS_FILE=\"$known_hosts\"" >"$destination"' \
        >"$mock_directory/ansible"
    chmod 0700 "$mock_directory/ansible"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'joined="$*"' \
        'if [[ "$joined" == *environments/prod/inventory.ini* ]]; then' \
        '  public_ip=3.12.65.199' \
        '  private_key=../morrowpal-prod-01.pem' \
        '  known_hosts=environments/prod/known_hosts' \
        'else' \
        '  public_ip=STAGING_PUBLIC_IP' \
        '  private_key=../morrowpal-staging-01.pem' \
        '  known_hosts=environments/staging/known_hosts' \
        'fi' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == inventory ]]; then public_ip=WRONG_PUBLIC_IP; fi' \
        'printf "{\"morrowpal_hosts\":{\"hosts\":[\"01\"]},\"_meta\":{\"hostvars\":{\"01\":{\"ansible_host\":\"%s\",\"ansible_user\":\"ec2-user\",\"ansible_ssh_private_key_file\":\"%s\",\"ansible_ssh_common_args\":\"-o UserKnownHostsFile=%s\"}}}}\n" "$public_ip" "$private_key" "$known_hosts"' \
        >"$mock_directory/ansible-inventory"
    chmod 0700 "$mock_directory/ansible-inventory"
}

install_mock_aws() {
    local mock_directory="$1"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'printf "aws:%s\n" "$*" >>"$MORROWPAL_MOCK_LOG"' \
        'service="${1:-}"' \
        'operation="${2:-}"' \
        'joined="$*"' \
        'environment="${MORROWPAL_MOCK_ENVIRONMENT:-staging}"' \
        'vpc_id="vpc-$environment"' \
        'subnet_id="subnet-$environment"' \
        'security_group_id="sg-$environment"' \
        'profile_name="morrowpal-$environment-profile"' \
        'profile_arn="arn:aws:iam::384078510608:instance-profile/$profile_name"' \
        'role_name="morrowpal-$environment-role"' \
        'role_arn="arn:aws:iam::384078510608:role/$role_name"' \
        'instance_id="i-$environment"' \
        'case "$service:$operation" in' \
        '  sts:get-caller-identity)' \
        '    if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == account ]]; then printf "000000000000\n"; else printf "384078510608\n"; fi' \
        '    ;;' \
        '  ec2:describe-subnets)' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == subnet-vpc ]] && vpc_id=vpc-other' \
        '    availability_zone=us-east-2c' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == subnet-az ]] && availability_zone=us-east-2b' \
        '    printf "{\"Subnets\":[{\"OwnerId\":\"384078510608\",\"VpcId\":\"%s\",\"AvailabilityZone\":\"%s\",\"State\":\"available\"}]}\n" "$vpc_id" "$availability_zone"' \
        '    ;;' \
        '  ec2:describe-security-groups)' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == security-group-vpc ]] && vpc_id=vpc-other' \
        '    tag_environment="$environment"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == security-group-environment ]] && tag_environment=prod' \
        '    if [[ "$environment" == prod ]]; then tags="[]"; else tags="[{\"Key\":\"Environment\",\"Value\":\"$tag_environment\"},{\"Key\":\"Application\",\"Value\":\"morrowpal\"}]"; fi' \
        '    printf "{\"SecurityGroups\":[{\"OwnerId\":\"384078510608\",\"VpcId\":\"%s\",\"Tags\":%s}]}\n" "$vpc_id" "$tags"' \
        '    ;;' \
        '  ec2:describe-key-pairs)' \
        '    if [[ "$environment" == prod ]]; then key_name=01; else key_name=morrowpal-staging-01; fi' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == key-pair ]] && key_name=wrong-key' \
        '    printf "{\"KeyPairs\":[{\"KeyName\":\"%s\"}]}\n" "$key_name"' \
        '    ;;' \
        '  cloudformation:describe-stacks)' \
        '    if [[ "$joined" == *"--stack-name morrowpal-$environment-ec2-access"* ]]; then' \
        '      output_role_arn="$role_arn"' \
        '      [[ "${MORROWPAL_MOCK_MISMATCH:-}" == access-account ]] && output_role_arn="arn:aws:iam::000000000000:role/$role_name"' \
        '      printf "{\"Stacks\":[{\"Outputs\":[{\"OutputKey\":\"InstanceProfileName\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"InstanceProfileArn\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"RoleArn\",\"OutputValue\":\"%s\"}]}]}\n" "$profile_name" "$profile_arn" "$output_role_arn"' \
        '    elif [[ "$joined" == *"--stack-name morrowpal-$environment-ec2"* ]]; then' \
        '      printf "{\"Stacks\":[{\"Outputs\":[{\"OutputKey\":\"InstanceId\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"AvailabilityZone\",\"OutputValue\":\"us-east-2c\"}]}]}\n" "$instance_id"' \
        '    else' \
        '      printf "ValidationError: Stack does not exist\n" >&2' \
        '      exit 255' \
        '    fi' \
        '    ;;' \
        '  iam:get-instance-profile)' \
        '    profile_role_name="$role_name"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == role ]] && profile_role_name=morrowpal-other-role' \
        '    printf "{\"InstanceProfile\":{\"Arn\":\"%s\",\"Roles\":[{\"RoleName\":\"%s\"}]}}\n" "$profile_arn" "$profile_role_name"' \
        '    ;;' \
        '  ec2:describe-instances)' \
        '    instance_environment="$environment"' \
        '    instance_profile_arn="$profile_arn"' \
        '    instance_subnet_id="$subnet_id"' \
        '    instance_security_group_id="$security_group_id"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-environment ]] && instance_environment=prod' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-profile ]] && instance_profile_arn="arn:aws:iam::384078510608:instance-profile/wrong"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-subnet ]] && instance_subnet_id=subnet-other' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-security-group ]] && instance_security_group_id=sg-other' \
        '    printf "{\"Reservations\":[{\"Instances\":[{\"InstanceId\":\"%s\",\"SubnetId\":\"%s\",\"Placement\":{\"AvailabilityZone\":\"us-east-2c\"},\"IamInstanceProfile\":{\"Arn\":\"%s\"},\"SecurityGroups\":[{\"GroupId\":\"%s\"}],\"State\":{\"Name\":\"running\"},\"Tags\":[{\"Key\":\"Application\",\"Value\":\"morrowpal\"},{\"Key\":\"Environment\",\"Value\":\"%s\"},{\"Key\":\"Name\",\"Value\":\"morrowpal-%s-01\"},{\"Key\":\"aws:cloudformation:stack-name\",\"Value\":\"morrowpal-%s-ec2\"}]}]}]}\n" "$instance_id" "$instance_subnet_id" "$instance_profile_arn" "$instance_security_group_id" "$instance_environment" "$environment" "$environment"' \
        '    ;;' \
        '  cloudformation:create-change-set)' \
        '    printf "{\"Id\":\"mock-change-set\"}\n"' \
        '    ;;' \
        '  *) printf "Unexpected mock AWS call: %s\n" "$joined" >&2; exit 2 ;;' \
        'esac' \
        >"$mock_directory/aws"
    chmod 0700 "$mock_directory/aws"
}

run_wrapper() {
    local environment="$1"
    local mismatch="$2"
    shift 2

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_MOCK_ENVIRONMENT="$environment" \
    MORROWPAL_MOCK_MISMATCH="$mismatch" \
        "$wrapper" "$environment" "$@"
}

main() {
    local cleanup_command
    local mismatch
    local output_file
    local test_directory
    local -a mismatches=(
        account
        inventory
        overlay
        prefix
        subnet-vpc
        subnet-az
        security-group-vpc
        security-group-environment
        key-pair
        access-account
        role
        instance-environment
        instance-profile
        instance-subnet
        instance-security-group
    )

    bash -n "$wrapper"
    test_directory="$(mktemp -d)"
    printf -v cleanup_command 'rm -rf -- %q' "$test_directory"
    trap "$cleanup_command" EXIT
    mock_directory="$test_directory/bin"
    mock_log="$test_directory/aws.log"
    output_file="$test_directory/output"
    install -d -m 0700 "$mock_directory"
    install_mock_ansible "$mock_directory"
    install_mock_aws "$mock_directory"

    : >"$mock_log"
    run_wrapper staging '' runtime-secrets safe-runtime-secrets --dry-run >"$output_file"
    grep -Fq 'Dry run: validation passed' "$output_file" \
        || fail "A valid staging dry run did not pass"
    if grep -Fq 'aws:cloudformation create-change-set' "$mock_log"; then
        fail "Dry run created a CloudFormation change set"
    fi

    for mismatch in "${mismatches[@]}"; do
        : >"$mock_log"
        if run_wrapper staging "$mismatch" runtime-secrets "reject-$mismatch" --dry-run \
                >"$output_file" 2>&1; then
            fail "Wrapper accepted mismatch: $mismatch"
        fi
        if grep -Fq 'aws:cloudformation create-change-set' "$mock_log"; then
            fail "Mismatch reached change-set creation: $mismatch"
        fi
    done

    if run_wrapper staging instance-environment ec2 reject-existing-ec2 --dry-run \
            >"$output_file" 2>&1; then
        fail "EC2 update accepted an existing instance from another environment"
    fi

    : >"$mock_log"
    if run_wrapper prod '' ecr missing-prod-confirmation --dry-run >/dev/null 2>&1; then
        fail "Production invocation did not require explicit confirmation"
    fi
    [[ ! -s "$mock_log" ]] \
        || fail "Unconfirmed production invocation contacted AWS"

    run_wrapper prod '' ecr confirmed-prod --confirm-production --dry-run >"$output_file"
    grep -Fq 'Environment: prod' "$output_file" \
        || fail "Confirmed production dry run selected the wrong environment"

    : >"$mock_log"
    run_wrapper staging '' ecr create-staging-ecr >"$output_file"
    grep -Fq 'aws:cloudformation create-change-set' "$mock_log" \
        || fail "Validated non-dry invocation did not create a change set"
    grep -Fq -- '--stack-name morrowpal-staging-ecr' "$mock_log" \
        || fail "Change set targeted the wrong stack"
    grep -Fq 'ParameterKey=Environment,ParameterValue=staging' "$mock_log" \
        || fail "Change set omitted the selected environment parameter"

    printf 'MorrowPal guarded infrastructure change-set validation passed.\n'
}

main "$@"
