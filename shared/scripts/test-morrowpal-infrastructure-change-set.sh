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
        '  aws_region=us-east-2' \
        '  availability_zone=us-east-2c' \
        'else' \
        '  environment=staging' \
        '  public_ip=STAGING_PUBLIC_IP' \
        '  private_key=../morrowpal-staging-01.pem' \
        '  known_hosts=environments/staging/known_hosts' \
        '  vpc_id=vpc-staging' \
        '  subnet_id=subnet-staging' \
        '  security_group_id=sg-staging' \
        '  key_name=morrowpal-staging-01' \
        '  aws_region=us-east-1' \
        '  availability_zone=us-east-1a' \
        'fi' \
        'instance_name="morrowpal-$environment-01"' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == other-environment ]]; then' \
        '  public_ip=3.12.65.199' \
        '  private_key=../morrowpal-prod-01.pem' \
        '  known_hosts=environments/prod/known_hosts' \
        '  vpc_id=vpc-prod' \
        '  subnet_id=subnet-prod' \
        '  security_group_id=sg-prod' \
        '  key_name=01' \
        '  instance_name=morrowpal-prod-01' \
        'fi' \
        'overlay_environment="$environment"' \
        'stack_prefix="morrowpal-$environment"' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == overlay ]]; then overlay_environment=prod; fi' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == prefix ]]; then stack_prefix=morrowpal-wrong; fi' \
        'printf "%s\n" \' \
        '  "MORROWPAL_ENVIRONMENT=\"$overlay_environment\"" \' \
        '  "MORROWPAL_AWS_ACCOUNT_ID=\"384078510608\"" \' \
        '  "MORROWPAL_AWS_REGION=\"$aws_region\"" \' \
        '  "MORROWPAL_AVAILABILITY_ZONE=\"$availability_zone\"" \' \
        '  "MORROWPAL_STACK_PREFIX=\"$stack_prefix\"" \' \
        '  "MORROWPAL_VPC_ID=\"$vpc_id\"" \' \
        '  "MORROWPAL_SUBNET_ID=\"$subnet_id\"" \' \
        '  "MORROWPAL_SECURITY_GROUP_ID=\"$security_group_id\"" \' \
        '  "MORROWPAL_EC2_KEY_NAME=\"$key_name\"" \' \
        '  "MORROWPAL_INSTANCE_NAME=\"$instance_name\"" \' \
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
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == other-environment ]]; then' \
        '  public_ip=3.12.65.199' \
        '  private_key=../morrowpal-prod-01.pem' \
        '  known_hosts=environments/prod/known_hosts' \
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
        'if [[ "$environment" == prod ]]; then availability_zone=us-east-2c; else availability_zone=us-east-1a; fi' \
        'resource_environment="$environment"' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == other-environment ]]; then resource_environment=prod; fi' \
        'vpc_id="vpc-$resource_environment"' \
        'subnet_id="subnet-$resource_environment"' \
        'security_group_id="sg-$resource_environment"' \
        'profile_name="morrowpal-$resource_environment-profile"' \
        'profile_arn="arn:aws:iam::384078510608:instance-profile/$profile_name"' \
        'role_name="morrowpal-$resource_environment-role"' \
        'role_arn="arn:aws:iam::384078510608:role/$role_name"' \
        'instance_id="i-$resource_environment"' \
        'case "$service:$operation" in' \
        '  sts:get-caller-identity)' \
        '    if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == account ]]; then printf "000000000000\n"; else printf "384078510608\n"; fi' \
        '    ;;' \
        '  ec2:describe-vpcs)' \
        '    owner_id=384078510608' \
        '    vpc_state=available' \
        '    resolved_vpc_id="$vpc_id"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == vpc-account ]] && owner_id=000000000000' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == vpc-state ]] && vpc_state=pending' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == vpc-id ]] && resolved_vpc_id=vpc-other' \
        '    printf "{\"Vpcs\":[{\"VpcId\":\"%s\",\"OwnerId\":\"%s\",\"State\":\"%s\"}]}\n" "$resolved_vpc_id" "$owner_id" "$vpc_state"' \
        '    ;;' \
        '  ec2:describe-subnets)' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == subnet-vpc ]] && vpc_id=vpc-other' \
        '    resolved_availability_zone="$availability_zone"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == subnet-az ]] && resolved_availability_zone=us-west-2a' \
        '    printf "{\"Subnets\":[{\"OwnerId\":\"384078510608\",\"VpcId\":\"%s\",\"AvailabilityZone\":\"%s\",\"State\":\"available\"}]}\n" "$vpc_id" "$resolved_availability_zone"' \
        '    ;;' \
        '  ec2:describe-security-groups)' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == security-group-vpc ]] && vpc_id=vpc-other' \
        '    tag_environment="$resource_environment"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == security-group-environment ]] && tag_environment=prod' \
        '    if [[ "$environment" == prod && "${MORROWPAL_MOCK_MISMATCH:-}" != other-environment ]]; then tags="[]"; else tags="[{\"Key\":\"Environment\",\"Value\":\"$tag_environment\"},{\"Key\":\"Application\",\"Value\":\"morrowpal\"}]"; fi' \
        '    printf "{\"SecurityGroups\":[{\"OwnerId\":\"384078510608\",\"VpcId\":\"%s\",\"Tags\":%s}]}\n" "$vpc_id" "$tags"' \
        '    ;;' \
        '  ec2:describe-key-pairs)' \
        '    if [[ "$resource_environment" == prod ]]; then key_name=01; else key_name=morrowpal-staging-01; fi' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == key-pair ]] && key_name=wrong-key' \
        '    printf "{\"KeyPairs\":[{\"KeyName\":\"%s\"}]}\n" "$key_name"' \
        '    ;;' \
        '  cloudformation:describe-stacks)' \
        '    if [[ "$joined" == *"--stack-name morrowpal-$environment-ec2-access"* ]]; then' \
        '      output_role_arn="$role_arn"' \
        '      [[ "${MORROWPAL_MOCK_MISMATCH:-}" == access-account ]] && output_role_arn="arn:aws:iam::000000000000:role/$role_name"' \
        '      printf "{\"Stacks\":[{\"Outputs\":[{\"OutputKey\":\"InstanceProfileName\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"InstanceProfileArn\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"RoleArn\",\"OutputValue\":\"%s\"}]}]}\n" "$profile_name" "$profile_arn" "$output_role_arn"' \
        '    elif [[ "$joined" == *"--stack-name morrowpal-$environment-ec2"* ]]; then' \
        '      printf "{\"Stacks\":[{\"Outputs\":[{\"OutputKey\":\"InstanceId\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"AvailabilityZone\",\"OutputValue\":\"%s\"}]}]}\n" "$instance_id" "$availability_zone"' \
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
        '    instance_environment="$resource_environment"' \
        '    instance_profile_arn="$profile_arn"' \
        '    instance_subnet_id="$subnet_id"' \
        '    instance_security_group_id="$security_group_id"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-environment ]] && instance_environment=prod' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-profile ]] && instance_profile_arn="arn:aws:iam::384078510608:instance-profile/wrong"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-subnet ]] && instance_subnet_id=subnet-other' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-security-group ]] && instance_security_group_id=sg-other' \
        '    printf "{\"Reservations\":[{\"Instances\":[{\"InstanceId\":\"%s\",\"SubnetId\":\"%s\",\"Placement\":{\"AvailabilityZone\":\"%s\"},\"IamInstanceProfile\":{\"Arn\":\"%s\"},\"SecurityGroups\":[{\"GroupId\":\"%s\"}],\"State\":{\"Name\":\"running\"},\"Tags\":[{\"Key\":\"Application\",\"Value\":\"morrowpal\"},{\"Key\":\"Environment\",\"Value\":\"%s\"},{\"Key\":\"Name\",\"Value\":\"morrowpal-%s-01\"},{\"Key\":\"aws:cloudformation:stack-name\",\"Value\":\"morrowpal-%s-ec2\"}]}]}]}\n" "$instance_id" "$instance_subnet_id" "$availability_zone" "$instance_profile_arn" "$instance_security_group_id" "$instance_environment" "$resource_environment" "$resource_environment"' \
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
    local private_key_file
    local public_key_file
    local test_directory
    local -a mismatches=(
        account
        inventory
        overlay
        prefix
        vpc-account
        vpc-id
        vpc-state
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
    private_key_file="$test_directory/private-key.pem"
    public_key_file="$test_directory/recovery-key.pub"
    install -d -m 0700 "$mock_directory"
    install_mock_ansible "$mock_directory"
    install_mock_aws "$mock_directory"
    printf '%s\n' \
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1vcnJvd3BhbC10ZXN0LWtleQ== ignored-comment' \
        >"$public_key_file"
    printf '%s\n' \
        '-----BEGIN PRIVATE KEY-----' \
        'test-only-private-material' \
        '-----END PRIVATE KEY-----' \
        >"$private_key_file"

    : >"$mock_log"
    run_wrapper staging '' prerequisites initial-prerequisites \
        --ssh-public-key-file "$public_key_file" \
        --ssh-ingress-cidr 203.0.113.10/32 \
        --dry-run >"$output_file"
    grep -Fq 'Stack: morrowpal-staging-prerequisites' "$output_file" \
        || fail "Prerequisites dry run targeted the wrong stack"
    grep -Fq 'SSH public key: validated; material hidden' "$output_file" \
        || fail "Prerequisites dry run did not report safe public-key validation"
    if grep -Fq 'AAAAC3Nza' "$output_file"; then
        fail "Prerequisites dry run printed public-key material"
    fi
    if grep -Eq 'describe-security-groups|describe-key-pairs|create-change-set' "$mock_log"; then
        fail "Prerequisites dry run required resources that it is meant to create"
    fi

    : >"$mock_log"
    run_wrapper staging '' prerequisites create-prerequisites \
        --ssh-public-key-file "$public_key_file" \
        --ssh-ingress-cidr 203.0.113.10/32 >"$output_file"
    grep -Fq -- '--stack-name morrowpal-staging-prerequisites' "$mock_log" \
        || fail "Prerequisites change set targeted the wrong stack"
    grep -Fq 'ParameterKey=VpcId,ParameterValue=vpc-staging' "$mock_log" \
        || fail "Prerequisites change set omitted the selected VPC"
    grep -Fq 'ParameterKey=KeyName,ParameterValue=morrowpal-staging-01' "$mock_log" \
        || fail "Prerequisites change set omitted the selected key name"
    grep -Fq 'ParameterKey=SshPublicKeyMaterial,ParameterValue=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG1vcnJvd3BhbC10ZXN0LWtleQ==' "$mock_log" \
        || fail "Prerequisites change set did not normalize the public key"
    grep -Fq 'ParameterKey=SshIngressCidr,ParameterValue=203.0.113.10/32' "$mock_log" \
        || fail "Prerequisites change set omitted the reviewed SSH CIDR"

    : >"$mock_log"
    if run_wrapper staging '' prerequisites reject-private-key \
            --ssh-public-key-file "$private_key_file" \
            --ssh-ingress-cidr 203.0.113.10/32 >"$output_file" 2>&1; then
        fail "Prerequisites accepted private key material"
    fi
    [[ ! -s "$mock_log" ]] \
        || fail "Private-key rejection contacted AWS"

    : >"$mock_log"
    run_wrapper staging '' prerequisites match-production-ssh \
            --ssh-public-key-file "$public_key_file" \
            --ssh-ingress-cidr 0.0.0.0/0 >"$output_file"
    grep -Fq 'ParameterKey=SshIngressCidr,ParameterValue=0.0.0.0/0' "$mock_log" \
        || fail "Prerequisites did not preserve explicitly selected production SSH access"

    : >"$mock_log"
    if run_wrapper staging '' prerequisites reject-invalid-ssh \
            --ssh-public-key-file "$public_key_file" \
            --ssh-ingress-cidr 256.0.0.1/32 >"$output_file" 2>&1; then
        fail "Prerequisites accepted an invalid SSH CIDR"
    fi
    [[ ! -s "$mock_log" ]] \
        || fail "Invalid SSH CIDR rejection contacted AWS"

    : >"$mock_log"
    if run_wrapper staging '' ecr reject-ssh-options \
            --ssh-public-key-file "$public_key_file" \
            --ssh-ingress-cidr 203.0.113.10/32 >"$output_file" 2>&1; then
        fail "A non-prerequisites stack accepted SSH bootstrap options"
    fi
    [[ ! -s "$mock_log" ]] \
        || fail "Invalid SSH bootstrap options contacted AWS"

    : >"$mock_log"
    run_wrapper staging '' runtime-secrets safe-runtime-secrets --dry-run >"$output_file"
    grep -Fq 'Dry run: validation passed' "$output_file" \
        || fail "A valid staging dry run did not pass"
    grep -Fq 'AWS Region: us-east-1' "$output_file" \
        || fail "Staging dry run did not select its configured Region"
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
    if run_wrapper staging other-environment runtime-secrets \
            reject-coherent-production-bindings >"$output_file" 2>&1; then
        fail "Staging accepted a coherent set of production resource bindings"
    fi
    grep -Fq 'Staging security group is missing its environment identity tags' \
        "$output_file" \
        || fail "Cross-environment fixture did not reach the environment identity guard"
    grep -Fq 'ec2 describe-subnets --subnet-ids subnet-prod' "$mock_log" \
        || fail "Cross-environment fixture did not resolve the production subnet"
    grep -Fq 'ec2 describe-security-groups --group-ids sg-prod' "$mock_log" \
        || fail "Cross-environment fixture did not resolve the production security group"
    if grep -Fq 'aws:cloudformation create-change-set' "$mock_log"; then
        fail "Production resource bindings reached staging change-set creation"
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
    grep -Fq -- '--region us-east-1' "$mock_log" \
        || fail "Staging change set targeted the wrong Region"

    : >"$mock_log"
    run_wrapper staging '' mysql-storage detach-staging-mysql \
        --detach-mysql-volume >"$output_file"
    grep -Fq 'ParameterKey=AttachVolume,ParameterValue=false' "$mock_log" \
        || fail "MySQL detach did not disable the volume attachment"

    : >"$mock_log"
    run_wrapper staging '' mysql-storage attach-staging-mysql >"$output_file"
    grep -Fq 'ParameterKey=AttachVolume,ParameterValue=true' "$mock_log" \
        || fail "MySQL attachment was not explicit"

    : >"$mock_log"
    if run_wrapper staging '' ecr invalid-detach-option \
            --detach-mysql-volume >"$output_file" 2>&1; then
        fail "MySQL detach option was accepted for a different stack kind"
    fi
    [[ ! -s "$mock_log" ]] \
        || fail "Invalid MySQL detach option contacted AWS"

    printf 'MorrowPal guarded infrastructure change-set validation passed.\n'
}

main "$@"
