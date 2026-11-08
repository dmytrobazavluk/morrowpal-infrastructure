#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly prod_directory="$(cd -- "$script_directory/.." && pwd)"
readonly repository_directory="$(cd -- "$prod_directory/.." && pwd)"
readonly service_script="$script_directory/morrowpal-service.sh"
readonly runtime_config_library="$script_directory/morrowpal-runtime-config.sh"
readonly environment_template="$repository_directory/shared/runtime/compose.env.j2"
readonly compose_file="$repository_directory/shared/docker-compose.yml"

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

assert_environment() {
    local environment_file="$1"
    local expected_region="$2"
    local expected_registry="$3"
    local expected_repository_prefix="$4"
    local expected_secrets_prefix="$5"
    local expected_app_domain="$6"
    local expected_website_domain="$7"
    local expected_deployment_root="$8"
    local expected_mysql_data_mount="$9"

    set -a
    # shellcheck source=/dev/null
    source "$environment_file"
    set +a
    # shellcheck source=morrowpal-runtime-config.sh
    source "$runtime_config_library"

    [[ "$MORROWPAL_AWS_REGION" == "$expected_region" ]] || fail "Unexpected AWS Region"
    [[ "$MORROWPAL_ECR_REGISTRY" == "$expected_registry" ]] || fail "Unexpected ECR registry"
    [[ "$MORROWPAL_ECR_REPOSITORY_PREFIX" == "$expected_repository_prefix" ]] \
        || fail "Unexpected ECR repository prefix"
    [[ "$MORROWPAL_APP_DOMAIN" == "$expected_app_domain" ]] || fail "Unexpected app domain"
    [[ "$MORROWPAL_WEBSITE_DOMAIN" == "$expected_website_domain" ]] \
        || fail "Unexpected website domain"
    [[ "$MORROWPAL_DEPLOYMENT_ROOT" == "$expected_deployment_root" ]] \
        || fail "Unexpected deployment root"
    [[ "$MORROWPAL_MYSQL_DATA_MOUNT" == "$expected_mysql_data_mount" ]] \
        || fail "Unexpected MySQL data mount"
    [[ "$(morrowpal_secret_reference "$MORROWPAL_SECRETS_PREFIX/mysql" password)" == \
        "{{resolve:secretsmanager:${expected_secrets_prefix}/mysql:SecretString:password}}" ]] \
        || fail "Unexpected MySQL application secret reference"
    [[ "$(morrowpal_secret_reference "$MORROWPAL_SECRETS_PREFIX/mysql-root" password)" == \
        "{{resolve:secretsmanager:${expected_secrets_prefix}/mysql-root:SecretString:password}}" ]] \
        || fail "Unexpected MySQL root secret reference"
    [[ "$(morrowpal_secret_reference "$MORROWPAL_SECRETS_PREFIX/jwt" value)" == \
        "{{resolve:secretsmanager:${expected_secrets_prefix}/jwt:SecretString:value}}" ]] \
        || fail "Unexpected JWT secret reference"
    [[ "$(morrowpal_secret_reference "$MORROWPAL_SECRETS_PREFIX/postmark" serverToken)" == \
        "{{resolve:secretsmanager:${expected_secrets_prefix}/postmark:SecretString:serverToken}}" ]] \
        || fail "Unexpected Postmark secret reference"
    [[ "$(morrowpal_secret_reference "$MORROWPAL_SECRETS_PREFIX/firebase-service-account")" == \
        "{{resolve:secretsmanager:${expected_secrets_prefix}/firebase-service-account}}" ]] \
        || fail "Unexpected Firebase secret reference"
    [[ "$(morrowpal_secret_reference "$MORROWPAL_SECRETS_PREFIX/store-review" value)" == \
        "{{resolve:secretsmanager:${expected_secrets_prefix}/store-review:SecretString:value}}" ]] \
        || fail "Unexpected store-review secret reference"
}

main() {
    local cleanup_command
    local prod_environment
    local staging_environment

    command -v ansible >/dev/null 2>&1 || fail "Required command not found: ansible"
    bash -n "$service_script"
    bash -n "$runtime_config_library"

    if grep -Eq 'morrowpal/prod|app\.morrowpal\.com|https://morrowpal\.com|384078510608' "$service_script"; then
        fail "Service helper contains a production-only environment value"
    fi
    [[ "$(grep -Fc 'morrowpal_secret_reference "$secrets_prefix/' "$service_script")" -eq 6 ]] \
        || fail "Service helper must derive all six runtime secret references from the selected prefix"
    grep -Fq -- '--env-file "$environment_file"' "$service_script" \
        || fail "Service helper must pass the selected environment file to Docker Compose"
    if grep -Eq '/opt/morrowpal|/var/lib/morrowpal' "$compose_file"; then
        fail "Compose file contains a hardcoded host deployment path"
    fi
    for recreate_option in --recreate-envoy --recreate-app --recreate-website; do
        grep -Fq -- "$recreate_option" "$service_script" \
            || fail "Service helper does not support $recreate_option"
    done
    grep -Fq 'compose up --detach --no-deps --force-recreate app' "$service_script" \
        || fail "Service helper does not recreate the app after a configuration change"
    grep -Fq 'compose up --detach --no-deps --force-recreate website' "$service_script" \
        || fail "Service helper does not recreate the website after a configuration change"

    prod_environment="$(mktemp)"
    staging_environment="$(mktemp)"
    printf -v cleanup_command \
        'rm -f -- %q %q' \
        "$prod_environment" \
        "$staging_environment"
    trap "$cleanup_command" EXIT
    render_environment prod "$prod_environment"
    render_environment staging "$staging_environment"

    assert_environment \
        "$prod_environment" \
        us-east-2 \
        384078510608.dkr.ecr.us-east-2.amazonaws.com \
        morrowpal/prod \
        morrowpal/prod \
        app.morrowpal.com \
        morrowpal.com \
        /opt/morrowpal \
        /var/lib/morrowpal
    assert_environment \
        "$staging_environment" \
        us-east-2 \
        384078510608.dkr.ecr.us-east-2.amazonaws.com \
        morrowpal/staging \
        morrowpal/staging \
        app.staging.morrowpal.com \
        staging.morrowpal.com \
        /opt/morrowpal \
        /var/lib/morrowpal

    printf 'MorrowPal service helper validation passed.\n'
}

main "$@"
