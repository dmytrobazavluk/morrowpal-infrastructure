#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly prod_directory="$(cd -- "$script_directory/.." && pwd)"
readonly repository_directory="$(cd -- "$prod_directory/.." && pwd)"
readonly release_script="$script_directory/morrowpal-deploy-release.sh"
readonly runtime_config_library="$script_directory/morrowpal-runtime-config.sh"
readonly environment_template="$prod_directory/templates/compose.env.j2"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

render_environment() {
    local environment="$1"
    local destination="$2"

    ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
    ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
        ansible localhost \
            -i localhost, \
            --connection local \
            --module-name ansible.builtin.template \
            --args "src=$environment_template dest=$destination mode=0600" \
            --extra-vars "@$repository_directory/environments/$environment/vars.yml" >/dev/null
}

install_mock_commands() {
    local mock_directory="$1"
    local dispatcher="$mock_directory/mock-command"
    local command_name

    install -d -m 0700 "$mock_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'command_name="$(basename -- "$0")"' \
        'printf "%s:%s\\n" "$command_name" "$*" >>"$MORROWPAL_MOCK_LOG"' \
        'case "$command_name" in' \
        '  aws) printf "mock-password\\n" ;;' \
        '  docker)' \
        '    if [[ "${1:-}" == login ]]; then cat >/dev/null; fi' \
        '    if [[ "${1:-}" == inspect ]]; then printf "172.20.0.10\\n"; fi' \
        '    if [[ "$*" == *" ps -q "* ]]; then printf "mock-container-id\\n"; fi' \
        '    ;;' \
        '  curl)' \
        "    if [[ \"\$*\" == *\"format=json\"* ]]; then printf '{\"stats\":[{\"value\":0}]}\\n'; fi" \
        '    ;;' \
        'esac' >"$dispatcher"
    chmod 0700 "$dispatcher"

    for command_name in aws chown curl docker flock sleep systemctl; do
        ln -s mock-command "$mock_directory/$command_name"
    done
}

assert_log_contains() {
    local log_file="$1"
    local expected="$2"

    grep -Fq -- "$expected" "$log_file" || fail "Missing mocked command: $expected"
}

main() {
    local cleanup_command
    local mock_directory
    local mock_log
    local prod_environment
    local staging_environment
    local test_directory
    local test_deployment_root

    command -v ansible >/dev/null 2>&1 || fail "Required command not found: ansible"
    bash -n "$release_script"

    if grep -Eq 'morrowpal/prod|384078510608|us-east-2|/opt/morrowpal' "$release_script"; then
        fail "Release helper contains a production-only environment value"
    fi

    test_directory="$(mktemp -d)"
    printf -v cleanup_command 'rm -rf -- %q' "$test_directory"
    trap "$cleanup_command" EXIT
    mock_directory="$test_directory/bin"
    mock_log="$test_directory/commands.log"
    prod_environment="$test_directory/prod.environment"
    staging_environment="$test_directory/staging.environment"
    test_deployment_root="$test_directory/deployment"

    install_mock_commands "$mock_directory"
    render_environment prod "$prod_environment"
    render_environment staging "$staging_environment"
    sed -i "s|MORROWPAL_DEPLOYMENT_ROOT=\"/opt/morrowpal\"|MORROWPAL_DEPLOYMENT_ROOT=\"$test_deployment_root\"|" \
        "$prod_environment"

    install -d -m 0750 "$test_deployment_root"
    printf 'services: {}\n' >"$test_deployment_root/docker-compose.yml"
    for tag_file in api-blue-image-tag api-green-image-tag job-image-tag app-image-tag website-image-tag; do
        printf 'build-1-abcdef0\n' >"$test_deployment_root/$tag_file"
    done

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_ENVIRONMENT_FILE="$prod_environment" \
    MORROWPAL_RUNTIME_CONFIG_LIBRARY="$runtime_config_library" \
    MORROWPAL_DEPLOYMENT_LOCK="$test_directory/deploy.lock" \
        "$release_script" build-2-bcdef01 >/dev/null

    assert_log_contains "$mock_log" 'aws:ecr get-login-password --region us-east-2'
    assert_log_contains "$mock_log" \
        'docker:login --username AWS --password-stdin 384078510608.dkr.ecr.us-east-2.amazonaws.com'
    assert_log_contains "$mock_log" \
        "docker:compose --env-file $prod_environment --project-directory $test_deployment_root --file $test_deployment_root/docker-compose.yml pull backend-api-blue"
    assert_log_contains "$mock_log" \
        "docker:compose --env-file $prod_environment --project-directory $test_deployment_root --file $test_deployment_root/docker-compose.yml pull backend-api-green"
    assert_log_contains "$mock_log" \
        "docker:compose --env-file $prod_environment --project-directory $test_deployment_root --file $test_deployment_root/docker-compose.yml pull backend-job-dispatch backend-job-cleanup"
    assert_log_contains "$mock_log" \
        'curl:--fail --silent --show-error --request POST http://127.0.0.1:9901/runtime_modify?routing.backend_api.backend_api_blue=0&routing.backend_api.backend_api_green=100'
    assert_log_contains "$mock_log" \
        'curl:--fail --silent --show-error --request POST http://127.0.0.1:9901/runtime_modify?routing.backend_api.backend_api_blue=50&routing.backend_api.backend_api_green=50'
    assert_log_contains "$mock_log" 'curl:--fail --silent --show-error http://127.0.0.1:8080/ready'

    grep -Fq 'MORROWPAL_ECR_REPOSITORY_PREFIX="morrowpal/staging"' "$staging_environment" \
        || fail "Staging release configuration does not select staging ECR repositories"

    printf 'MorrowPal blue-green release helper validation passed.\n'
}

main "$@"
