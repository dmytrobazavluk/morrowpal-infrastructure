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
        'ec2_stack="morrowpal-$environment-ec2"' \
        'case "${MORROWPAL_MOCK_MISMATCH:-}" in candidate*) ec2_stack="$ec2_stack-os-align-01" ;; active-stack-foreign) ec2_stack=morrowpal-other-ec2 ;; active-stack-empty) ec2_stack="" ;; esac' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == overlay ]]; then overlay_environment=prod; fi' \
        'if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == prefix ]]; then stack_prefix=morrowpal-wrong; fi' \
        'printf "%s\n" \' \
        '  "MORROWPAL_ENVIRONMENT=\"$overlay_environment\"" \' \
        '  "MORROWPAL_AWS_ACCOUNT_ID=\"384078510608\"" \' \
        '  "MORROWPAL_AWS_REGION=\"$aws_region\"" \' \
        '  "MORROWPAL_AVAILABILITY_ZONE=\"$availability_zone\"" \' \
        '  "MORROWPAL_STACK_PREFIX=\"$stack_prefix\"" \' \
        '  "MORROWPAL_EC2_STACK_NAME=\"$ec2_stack\"" \' \
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
        'ec2_stack="morrowpal-$environment-ec2"' \
        'case "${MORROWPAL_MOCK_MISMATCH:-}" in candidate*) ec2_stack="$ec2_stack-os-align-01"; instance_id="$instance_id-candidate" ;; esac' \
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
        '    if [[ "$joined" == *"--stack-name morrowpal-$environment-ec2-os-align-02"* && "${MORROWPAL_MOCK_MISMATCH:-}" != create-candidate-existing ]]; then printf "Stack does not exist\n" >&2; exit 255; fi' \
        '    if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == stack-tags && "$joined" == *"--stack-name morrowpal-$environment-ecr"* ]]; then' \
        '      printf "%s\n" '\''{"Stacks":[{"Tags":[{"Key":"Owner","Value":"fixture"}]}]}'\''' \
        '      exit 0' \
        '    fi' \
        '    if [[ "$joined" == *"--stack-name morrowpal-$environment-ec2-access"* ]]; then' \
        '      output_role_arn="$role_arn"' \
        '      [[ "${MORROWPAL_MOCK_MISMATCH:-}" == access-account ]] && output_role_arn="arn:aws:iam::000000000000:role/$role_name"' \
        '      printf "{\"Stacks\":[{\"Outputs\":[{\"OutputKey\":\"InstanceProfileName\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"InstanceProfileArn\",\"OutputValue\":\"%s\"},{\"OutputKey\":\"RoleArn\",\"OutputValue\":\"%s\"}]}]}\n" "$profile_name" "$profile_arn" "$output_role_arn"' \
        '    elif [[ "$joined" == *"--stack-name morrowpal-$environment-ec2"* ]]; then' \
        '      if [[ "${MORROWPAL_MOCK_MISMATCH:-}" == new-ec2* || "${MORROWPAL_MOCK_MISMATCH:-}" == candidate-missing ]]; then printf "Stack does not exist\n" >&2; exit 255; fi' \
        '      output_stack="$ec2_stack"; output_status=CREATE_COMPLETE' \
        '      [[ "${MORROWPAL_MOCK_MISMATCH:-}" == candidate-wrong-stack ]] && output_stack="morrowpal-$environment-ec2"' \
        '      [[ "${MORROWPAL_MOCK_MISMATCH:-}" == candidate-unstable ]] && output_status=UPDATE_IN_PROGRESS' \
        '      jq -n --arg id "$instance_id" --arg zone "$availability_zone" --arg stack "$output_stack" --arg status "$output_status" --arg environment "$environment" "{Stacks:[{StackId:(\"arn:aws:cloudformation:us-east-\" + (if \$environment == \"prod\" then \"2\" else \"1\" end) + \":384078510608:stack/\" + \$stack + \"/test\"),StackStatus:\$status,Outputs:[{OutputKey:\"InstanceId\",OutputValue:\$id},{OutputKey:\"AvailabilityZone\",OutputValue:\$zone}]}]}"' \
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
        '    image_id=ami-0123456789abcdef0' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == ami ]] && image_id=invalid-image' \
        '    instance_stack="$ec2_stack"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == candidate-wrong-tag ]] && instance_stack="morrowpal-$environment-ec2"' \
        '    {' \
        '    instance_environment="$resource_environment"' \
        '    instance_profile_arn="$profile_arn"' \
        '    instance_subnet_id="$subnet_id"' \
        '    instance_security_group_id="$security_group_id"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-environment ]] && instance_environment=prod' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-profile ]] && instance_profile_arn="arn:aws:iam::384078510608:instance-profile/wrong"' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-subnet ]] && instance_subnet_id=subnet-other' \
        '    [[ "${MORROWPAL_MOCK_MISMATCH:-}" == instance-security-group ]] && instance_security_group_id=sg-other' \
        '    printf "{\"Reservations\":[{\"Instances\":[{\"InstanceId\":\"%s\",\"SubnetId\":\"%s\",\"Placement\":{\"AvailabilityZone\":\"%s\"},\"IamInstanceProfile\":{\"Arn\":\"%s\"},\"SecurityGroups\":[{\"GroupId\":\"%s\"}],\"State\":{\"Name\":\"running\"},\"Tags\":[{\"Key\":\"Application\",\"Value\":\"morrowpal\"},{\"Key\":\"Environment\",\"Value\":\"%s\"},{\"Key\":\"Name\",\"Value\":\"morrowpal-%s-01\"},{\"Key\":\"aws:cloudformation:stack-name\",\"Value\":\"morrowpal-%s-ec2\"}]}]}]}\n" "$instance_id" "$instance_subnet_id" "$availability_zone" "$instance_profile_arn" "$instance_security_group_id" "$instance_environment" "$resource_environment" "$resource_environment"' \
        '    } | jq --arg image "$image_id" --arg stack "$instance_stack" ".Reservations[0].Instances[0].ImageId = \$image | .Reservations[0].Instances[0].Tags |= map(if .Key == \"aws:cloudformation:stack-name\" then .Value = \$stack else . end)"' \
        '    ;;' \
        '  ec2:describe-images)' \
        '    image_id=ami-11111111111111111; [[ "$environment" != prod ]] || image_id=ami-22222222222222222' \
        '    image_name=al2023-ami-2023.12.20260803.3-kernel-6.1-x86_64; owner=137112412989; architecture=x86_64' \
        '    state=available; root=ebs; virtualization=hvm; allowed=true; deprecated=2000-01-01T00:00:00.000Z' \
        '    mismatch="${MORROWPAL_MOCK_MISMATCH:-}"' \
        '    case "$mismatch" in' \
        '      new-ec2-ami) image_id=invalid-image ;;' \
        '      new-ec2-name) image_name=unreviewed-image ;;' \
        '      new-ec2-owner) owner=000000000000 ;;' \
        '      new-ec2-architecture) architecture=arm64 ;;' \
        '      new-ec2-disabled) state=disabled ;;' \
        '      new-ec2-root) root=instance-store ;;' \
        '      new-ec2-virtualization) virtualization=paravirtual ;;' \
        '      new-ec2-blocked) allowed=false ;;' \
        '      new-ec2-no-deprecation) deprecated="" ;;' \
        '      new-ec2-future-deprecation) deprecated=2999-01-01T00:00:00.000Z ;;' \
        '      new-ec2-query-error) exit 254 ;;' \
        '    esac' \
        '    jq -n --arg id "$image_id" --arg name "$image_name" --arg owner "$owner" --arg arch "$architecture" \' \
        '      --arg state "$state" --arg root "$root" --arg virtualization "$virtualization" --arg deprecated "$deprecated" \' \
        '      --argjson allowed "$allowed" --arg mismatch "$mismatch" \' \
        '      "{Images:[{ImageId:\$id,Name:\$name,OwnerId:\$owner,Architecture:\$arch,State:\$state,RootDeviceType:\$root,VirtualizationType:\$virtualization,ImageAllowed:\$allowed,DeprecationTime:(if \$deprecated == \"\" then null else \$deprecated end)}]} | if \$mismatch == \"new-ec2-missing\" then .Images=[] elif \$mismatch == \"new-ec2-ambiguous\" then .Images += .Images else . end"' \
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
        "${policy_wrapper:-$wrapper}" "$environment" "$@"
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
    grep -Fq '"Key":"Environment","Value":"staging"' "$mock_log" \
        || fail 'Staging change set omitted its stack environment tag'
    grep -Fq '"Key":"Application","Value":"morrowpal"' "$mock_log" \
        || fail 'Change set omitted its stack application tag'

    : >"$mock_log"
    run_wrapper staging stack-tags ecr preserve-extra-stack-tags >"$output_file"
    grep -Fq '"Key":"Owner","Value":"fixture"' "$mock_log" \
        || fail 'Stack tag update discarded an existing custom tag'
    : >"$mock_log"
    run_wrapper prod '' ecr production-stack-tags --confirm-production >"$output_file"
    grep -Fq '"Key":"Environment","Value":"prod"' "$mock_log" \
        || fail 'Confirmed production change set received the wrong environment tag'

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

    for environment in staging prod; do
        : >"$mock_log"
        confirmation=()
        [[ "$environment" != prod ]] || confirmation=(--confirm-production)
        run_wrapper "$environment" '' ec2 preserve-current-ami "${confirmation[@]}" >"$output_file"
        grep -Fq 'ParameterKey=AmiId,ParameterValue=ami-0123456789abcdef0' "$mock_log" \
            || fail 'EC2 update did not preserve the current AMI'
        if grep -Eq 'ssm get-parameter|ec2 describe-images' "$mock_log"; then fail 'Routine update resolved a new AMI'; fi
    done
    for environment in staging prod; do
        : >"$mock_log"
        confirmation=()
        expected_region=us-east-1; expected_ami=ami-11111111111111111
        if [[ "$environment" == prod ]]; then
            confirmation=(--confirm-production)
            expected_region=us-east-2; expected_ami=ami-22222222222222222
        fi
        run_wrapper "$environment" new-ec2 ec2 create-host "${confirmation[@]}" >"$output_file"
        grep -Fq "ParameterKey=AmiId,ParameterValue=$expected_ami" "$mock_log" || fail 'New host used the wrong regional image'
        grep -Fq -- "--region $expected_region" "$mock_log" || fail 'Image lookup omitted the selected Region'
        grep -Fq -- '--owners 137112412989' "$mock_log" || fail 'Image lookup omitted its trusted owner'
        grep -Fq 'Name=name,Values=al2023-ami-2023.12.20260803.3-kernel-6.1-x86_64' "$mock_log" || fail 'Image lookup did not pin the exact release'
        grep -Fq -- '--include-deprecated' "$mock_log" || fail 'Reviewed deprecated image was hidden from lookup'
        if grep -Fq 'ssm get-parameter' "$mock_log"; then fail 'Creation used a floating image alias'; fi
    done
    for mismatch in ami new-ec2-ami new-ec2-name new-ec2-owner new-ec2-architecture new-ec2-disabled new-ec2-root new-ec2-virtualization new-ec2-blocked new-ec2-missing new-ec2-ambiguous new-ec2-query-error; do
        : >"$mock_log"
        if run_wrapper staging "$mismatch" ec2 reject-invalid-ami >"$output_file" 2>&1; then
            fail "Invalid AMI was accepted: $mismatch"
        fi
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Invalid AMI reached change-set creation'; fi
    done
    # Mutate only an isolated policy fixture; never edit the reviewed source policy.
    policy_fixture="$test_directory/policy-fixture"
    mkdir -p "$policy_fixture/shared/scripts" "$policy_fixture/shared/cloudformation" \
        "$policy_fixture/shared/runtime" "$policy_fixture/environments/"{prod,staging}
    cp "$wrapper" "$script_directory/morrowpal-runtime-config.sh" "$policy_fixture/shared/scripts/"
    cp "$script_directory/../cloudformation/ec2.yml" "$policy_fixture/shared/cloudformation/"
    cp "$script_directory/../runtime/cloudformation.env.j2" "$policy_fixture/shared/runtime/"
    touch "$policy_fixture/environments/"{prod,staging}/{vars.yml,inventory.ini}
    policy_wrapper="$policy_fixture/shared/scripts/morrowpal-infrastructure-change-set.sh"
    for expression in '.name="wildcard-*"' '.ownerId="bad-owner"' '.architecture="arm64"' '.deprecatedImageExceptionName="other-release"' 'del(.name)'; do
        jq "$expression" "$script_directory/../ec2-image.json" >"$policy_fixture/shared/ec2-image.json"
        : >"$mock_log"
        if run_wrapper staging new-ec2 ec2 invalid-image-policy >"$output_file" 2>&1; then fail 'Invalid image policy accepted'; fi
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Invalid policy reached change-set creation'; fi
    done
    : >"$mock_log"
    run_wrapper prod '' ec2 preserve-with-invalid-creation-policy --confirm-production >"$output_file"
    if grep -Fq 'ec2 describe-images' "$mock_log"; then fail 'Existing host update consulted creation policy'; fi
    grep -Fq 'ParameterKey=AmiId,ParameterValue=ami-0123456789abcdef0' "$mock_log" || fail 'Existing AMI changed with invalid creation policy'
    jq 'del(.deprecatedImageExceptionName)' "$script_directory/../ec2-image.json" >"$policy_fixture/shared/ec2-image.json"
    : >"$mock_log"
    if run_wrapper staging new-ec2 ec2 reject-unapproved-deprecation >"$output_file" 2>&1; then fail 'Deprecated image accepted without exact exception'; fi
    if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Unapproved deprecated image reached change-set creation'; fi
    for mismatch in new-ec2-no-deprecation new-ec2-future-deprecation; do
        run_wrapper staging "$mismatch" ec2 available-image >"$output_file"
    done
    unset policy_wrapper
    for environment in staging prod; do
        confirmation=()
        [[ "$environment" != prod ]] || confirmation=(--confirm-production)
        : >"$mock_log"
        run_wrapper "$environment" candidate mysql-storage candidate-consumer "${confirmation[@]}" >"$output_file"
        grep -Fq "ParameterKey=InstanceId,ParameterValue=i-$environment-candidate" "$mock_log" || fail 'Consumer did not bind the candidate instance'
        : >"$mock_log"
        run_wrapper "$environment" candidate ec2 candidate-update "${confirmation[@]}" >"$output_file"
        grep -Fq "cloudformation create-change-set --stack-name morrowpal-$environment-ec2-os-align-01" "$mock_log" || fail 'EC2 update targeted the canonical stack instead of the active candidate'
    done
    for mismatch in active-stack-foreign active-stack-empty candidate-wrong-stack candidate-wrong-tag candidate-unstable candidate-missing; do
        : >"$mock_log"
        if run_wrapper staging "$mismatch" ec2 reject-active-stack >"$output_file" 2>&1; then fail "Accepted invalid active stack: $mismatch"; fi
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Invalid active stack reached change-set creation'; fi
    done
    candidate_config_digest="$(sha256sum "$script_directory/../../environments/"{prod,staging}/vars.yml)"
    for environment in staging prod; do
        confirmation=()
        expected_ami=ami-11111111111111111
        if [[ "$environment" == prod ]]; then confirmation=(--confirm-production); expected_ami=ami-22222222222222222; fi
        : >"$mock_log"
        run_wrapper "$environment" '' ec2 create-inactive-candidate --candidate-suffix os-align-02 "${confirmation[@]}" >"$output_file"
        grep -Fq "cloudformation create-change-set --stack-name morrowpal-$environment-ec2-os-align-02" "$mock_log" || fail 'Candidate creation targeted the wrong stack'
        grep -Fq -- '--change-set-type CREATE' "$mock_log" || fail 'Candidate was not CREATE-only'
        grep -Fq "ParameterKey=AmiId,ParameterValue=$expected_ami" "$mock_log" || fail 'Candidate did not use pinned regional AMI'
        grep -Fq -- "--stack-name morrowpal-$environment-ec2 " "$mock_log" || fail 'Candidate creation did not validate the active stack'
        grep -Fq 'Active EC2 instance retained:' "$output_file" || fail 'Candidate plan did not identify the preserved active host'
        if grep -Eq 'execute-change-set|stop-instances|start-instances|ParameterKey=InstanceId' "$mock_log"; then fail 'Candidate creation attempted a host handoff'; fi
        : >"$mock_log"
        run_wrapper "$environment" '' ec2 preview-candidate --candidate-suffix os-align-02 "${confirmation[@]}" --dry-run >"$output_file"
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Candidate dry run wrote a change set'; fi
    done
    : >"$mock_log"
    run_wrapper staging candidate ec2 create-next-candidate --candidate-suffix os-align-02 >"$output_file"
    for mismatch in create-candidate-existing candidate-wrong-stack candidate-wrong-tag candidate-unstable candidate-missing instance-environment instance-profile instance-subnet; do
        : >"$mock_log"
        if run_wrapper staging "$mismatch" ec2 reject-candidate --candidate-suffix os-align-02 >"$output_file" 2>&1; then fail "Candidate accepted $mismatch"; fi
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Invalid candidate reached change-set creation'; fi
    done
    : >"$mock_log"
    if run_wrapper staging '' ec2 reject-existing-role-stack --candidate-suffix access >"$output_file" 2>&1; then fail 'Candidate overwrote an existing non-EC2 stack'; fi
    if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Existing candidate name reached a write'; fi
    for suffix in '' '-leading' 'trailing-' 'double--hyphen' 'bad_name' 'bad/name'; do
        : >"$mock_log"
        if run_wrapper staging '' ec2 invalid-suffix --candidate-suffix "$suffix" >"$output_file" 2>&1; then fail 'Invalid candidate suffix accepted'; fi
        [[ ! -s "$mock_log" ]] || fail 'Malformed suffix contacted AWS'
    done
    printf -v long_suffix '%0128d' 0
    : >"$mock_log"
    if run_wrapper staging '' ec2 long-suffix --candidate-suffix "$long_suffix" >"$output_file" 2>&1; then fail 'Overlong candidate name accepted'; fi
    [[ ! -s "$mock_log" ]] || fail 'Overlong candidate name contacted AWS'
    for arguments in 'ec2 no-suffix --candidate-suffix' 'ec2 duplicate --candidate-suffix first --candidate-suffix second' 'ecr wrong-kind --candidate-suffix test'; do
        read -r -a candidate_arguments <<<"$arguments"
        : >"$mock_log"
        if run_wrapper staging '' "${candidate_arguments[@]}" >"$output_file" 2>&1; then fail 'Invalid candidate arguments accepted'; fi
        [[ ! -s "$mock_log" ]] || fail 'Invalid candidate arguments contacted AWS'
    done
    : >"$mock_log"
    if run_wrapper staging candidate ec2 reject-active-candidate --candidate-suffix os-align-01 >"$output_file" 2>&1; then fail 'Candidate targeted the active stack'; fi
    [[ ! -s "$mock_log" ]] || fail 'Active-stack collision contacted AWS'
    if run_wrapper prod '' ec2 unconfirmed-candidate --candidate-suffix os-align-02 >"$output_file" 2>&1; then fail 'Production candidate lacked confirmation'; fi
    [[ ! -s "$mock_log" ]] || fail 'Unconfirmed production candidate contacted AWS'
    [[ "$candidate_config_digest" == "$(sha256sum "$script_directory/../../environments/"{prod,staging}/vars.yml)" ]] || fail 'Candidate creation changed active configuration'
    : >"$mock_log"
    run_wrapper staging '' auto-stop nightly-stop >"$output_file"
    grep -Fq -- '--stack-name morrowpal-staging-auto-stop' "$mock_log" || fail 'Auto-stop targeted the wrong stack'
    grep -Fq 'ParameterKey=InstanceId,ParameterValue=i-staging' "$mock_log" || fail 'Auto-stop omitted the validated staging instance'
    grep -Fq -- '--capabilities CAPABILITY_IAM' "$mock_log" || fail 'Auto-stop omitted IAM capability'
    : >"$mock_log"
    run_wrapper staging '' auto-stop preview-nightly-stop --dry-run >"$output_file"
    if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Auto-stop dry run mutated AWS'; fi
    : >"$mock_log"
    if run_wrapper prod '' auto-stop reject-prod --confirm-production >"$output_file" 2>&1; then
        fail 'Auto-stop accepted production'
    fi
    [[ ! -s "$mock_log" ]] || fail 'Production auto-stop contacted AWS'
    for mismatch in instance-environment instance-subnet instance-security-group; do
        : >"$mock_log"
        if run_wrapper staging "$mismatch" auto-stop reject-mismatch >"$output_file" 2>&1; then
            fail "Auto-stop accepted $mismatch"
        fi
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Mismatched auto-stop target reached change-set creation'; fi
    done

    export MORROWPAL_MONTHLY_BUDGET_USD=15 MORROWPAL_BUDGET_ALERT_EMAIL=budget@example.com
    : >"$mock_log"
    run_wrapper staging '' budget create-budget >"$output_file"
    grep -Fq -- '--stack-name morrowpal-staging-budget' "$mock_log" || fail 'Budget targeted the wrong stack'
    grep -Fq 'ParameterKey=MonthlyBudgetUsd,ParameterValue=15' "$mock_log" || fail 'Budget omitted the amount'
    grep -Fq 'ParameterKey=AlertEmail,ParameterValue=budget@example.com' "$mock_log" || fail 'Budget omitted the recipient'
    if grep -Eq 'aws:ec2 |aws:iam ' "$mock_log"; then fail 'Budget unnecessarily required host resources'; fi
    for amount in 0 -1 15USD 1.001; do
        export MORROWPAL_MONTHLY_BUDGET_USD="$amount"
        : >"$mock_log"
        if run_wrapper staging '' budget reject-budget >"$output_file" 2>&1; then fail 'Invalid budget amount accepted'; fi
        if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Invalid amount reached change-set creation'; fi
    done
    export MORROWPAL_MONTHLY_BUDGET_USD=15 MORROWPAL_BUDGET_ALERT_EMAIL=invalid-address
    : >"$mock_log"
    if run_wrapper staging '' budget reject-email >"$output_file" 2>&1; then fail 'Invalid budget email accepted'; fi
    if grep -Fq 'cloudformation create-change-set' "$mock_log"; then fail 'Invalid email reached change-set creation'; fi
    unset MORROWPAL_MONTHLY_BUDGET_USD MORROWPAL_BUDGET_ALERT_EMAIL
    printf 'MorrowPal guarded infrastructure change-set validation passed.\n'
}

main "$@"
