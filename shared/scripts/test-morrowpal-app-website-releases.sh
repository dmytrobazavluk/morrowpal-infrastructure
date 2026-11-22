#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly shared_directory="$(cd -- "$script_directory/.." && pwd)"
readonly repository_directory="$(cd -- "$shared_directory/.." && pwd)"
readonly app_release_script="$script_directory/morrowpal-deploy-app.sh"
readonly website_release_script="$script_directory/morrowpal-deploy-website.sh"
readonly runtime_config_library="$script_directory/morrowpal-runtime-config.sh"
readonly environment_template="$repository_directory/shared/runtime/compose.env.j2"

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
        '    if [[ "${1:-}" == inspect ]]; then printf "healthy\\n"; fi' \
        '    if [[ "$*" == *" ps -q "* ]]; then printf "mock-container-id\\n"; fi' \
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

read_environment_value() {
    local environment_file="$1"
    local variable_name="$2"

    (
        # shellcheck source=/dev/null
        source "$environment_file"
        printf '%s' "${!variable_name}"
    )
}

run_environment_test() {
    local environment="$1"
    local expected_repository_prefix="$2"
    local expected_app_domain="$3"
    local expected_website_domain="$4"
    local test_root="$5"
    local environment_file="$test_root/environment"
    local deployment_root="$test_root/deployment"
    local mock_directory="$test_root/bin"
    local mock_log="$test_root/commands.log"
    local aws_region
    local ecr_registry
    local tag_file

    install_mock_commands "$mock_directory"
    render_environment "$environment" "$environment_file"
    aws_region="$(read_environment_value "$environment_file" MORROWPAL_AWS_REGION)"
    ecr_registry="$(read_environment_value "$environment_file" MORROWPAL_ECR_REGISTRY)"
    sed -i "s|MORROWPAL_DEPLOYMENT_ROOT=\"/opt/morrowpal\"|MORROWPAL_DEPLOYMENT_ROOT=\"$deployment_root\"|" \
        "$environment_file"

    install -d -m 0750 "$deployment_root"
    printf 'services: {}\n' >"$deployment_root/docker-compose.yml"
    for tag_file in api-blue-image-tag api-green-image-tag job-image-tag app-image-tag website-image-tag; do
        printf 'build-1-abcdef0\n' >"$deployment_root/$tag_file"
    done

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_ENVIRONMENT_FILE="$environment_file" \
    MORROWPAL_RUNTIME_CONFIG_LIBRARY="$runtime_config_library" \
    MORROWPAL_DEPLOYMENT_LOCK="$test_root/deploy.lock" \
        "$app_release_script" build-2-bcdef01 >/dev/null

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_ENVIRONMENT_FILE="$environment_file" \
    MORROWPAL_RUNTIME_CONFIG_LIBRARY="$runtime_config_library" \
    MORROWPAL_DEPLOYMENT_LOCK="$test_root/deploy.lock" \
        "$website_release_script" build-3-cdef012 >/dev/null

    grep -Fq "MORROWPAL_ECR_REPOSITORY_PREFIX=\"$expected_repository_prefix\"" "$environment_file" \
        || fail "$environment release configuration selected the wrong ECR repository prefix"
    assert_log_contains "$mock_log" "aws:ecr get-login-password --region $aws_region"
    assert_log_contains "$mock_log" \
        "docker:login --username AWS --password-stdin $ecr_registry"
    assert_log_contains "$mock_log" \
        "docker:compose --env-file $environment_file --project-directory $deployment_root --file $deployment_root/docker-compose.yml pull app"
    assert_log_contains "$mock_log" \
        "docker:compose --env-file $environment_file --project-directory $deployment_root --file $deployment_root/docker-compose.yml pull website"
    assert_log_contains "$mock_log" \
        "curl:--fail --silent --show-error --resolve ${expected_app_domain}:443:127.0.0.1 https://${expected_app_domain}/ready"
    assert_log_contains "$mock_log" \
        "curl:--fail --silent --show-error --resolve ${expected_website_domain}:443:127.0.0.1 https://${expected_website_domain}/ready"
    assert_log_contains "$mock_log" \
        "curl:--fail --silent --show-error --resolve ${expected_website_domain}:443:127.0.0.1 https://${expected_website_domain}/child-safety/"
}

main() {
    local cleanup_command
    local test_directory

    command -v ansible >/dev/null 2>&1 || fail "Required command not found: ansible"
    bash -n "$app_release_script"
    bash -n "$website_release_script"

    if grep -Eq 'morrowpal/prod|384078510608|us-east-2|/opt/morrowpal|app\.morrowpal\.com' \
            "$app_release_script" "$website_release_script"; then
        fail "App or website release helper contains a production-only environment value"
    fi

    test_directory="$(mktemp -d)"
    printf -v cleanup_command 'rm -rf -- %q' "$test_directory"
    trap "$cleanup_command" EXIT
    install -d -m 0700 "$test_directory/prod" "$test_directory/staging"

    run_environment_test \
        prod \
        morrowpal/prod \
        app.morrowpal.com \
        morrowpal.com \
        "$test_directory/prod"
    run_environment_test \
        staging \
        morrowpal/staging \
        app.staging.morrowpal.com \
        staging.morrowpal.com \
        "$test_directory/staging"

    printf 'MorrowPal app and website release helper validation passed.\n'
}

main "$@"
