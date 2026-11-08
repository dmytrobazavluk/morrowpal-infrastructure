#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROD_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_DIR="$(cd -- "$PROD_DIR/.." && pwd)"
readonly SHARED_DIR="$REPOSITORY_DIR/shared"
readonly CLOUDFORMATION_DIR="$REPOSITORY_DIR/shared/cloudformation"
readonly COMPOSE_BASELINE_FILE="$PROD_DIR/baselines/docker-compose-production.sha256"
readonly COMPOSE_ENV_TEMPLATE="$SHARED_DIR/runtime/compose.env.j2"
readonly ENVOY_BASELINE_FILE="$PROD_DIR/baselines/envoy-production.sha256"
readonly ENVOY_TEMPLATE="$SHARED_DIR/runtime/envoy/envoy.yaml.j2"
readonly AWS_REGION="us-east-2"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

render_compose() {
    local compose_env_file="$1"

    env \
        API_BLUE_IMAGE_TAG=validation \
        API_GREEN_IMAGE_TAG=validation \
        JOB_IMAGE_TAG=validation \
        APP_IMAGE_TAG=validation \
        WEBSITE_IMAGE_TAG=validation \
        docker compose \
            --env-file "$compose_env_file" \
            --project-directory "$SHARED_DIR" \
            --file "$SHARED_DIR/docker-compose.yml" \
            config --format json
}

render_compose_environment() {
    local environment="$1"
    local destination="$2"
    local vars_file="$REPOSITORY_DIR/environments/$environment/vars.yml"

    ANSIBLE_CONFIG="$REPOSITORY_DIR/ansible.cfg" \
    ANSIBLE_REMOTE_TEMP="/tmp/morrowpal-ansible-remote" \
        ansible localhost \
            -i localhost, \
            --connection local \
            --module-name ansible.builtin.template \
            --args "src=$COMPOSE_ENV_TEMPLATE dest=$destination mode=0600" \
            --extra-vars "@$vars_file" >/dev/null
}

render_envoy_environment() {
    local environment="$1"
    local destination="$2"
    local vars_file="$REPOSITORY_DIR/environments/$environment/vars.yml"

    ANSIBLE_CONFIG="$REPOSITORY_DIR/ansible.cfg" \
    ANSIBLE_REMOTE_TEMP="/tmp/morrowpal-ansible-remote" \
        ansible localhost \
            -i localhost, \
            --connection local \
            --module-name ansible.builtin.template \
            --args "src=$ENVOY_TEMPLATE dest=$destination mode=0600" \
            --extra-vars "@$vars_file" >/dev/null
}

main() {
    local actual_digest
    local cleanup_command
    local digest_output
    local expected_digest
    local envoy_actual_digest
    local envoy_expected_digest
    local expected_staging_value
    local prod_envoy_file
    local forbidden_value
    local prod_compose_env_file
    local prod_render
    local staging_compose_env_file
    local staging_render
    local staging_envoy_file
    local -a templates=(
        "$CLOUDFORMATION_DIR/ecr.yml"
        "$CLOUDFORMATION_DIR/ec2-access.yml"
        "$CLOUDFORMATION_DIR/ec2.yml"
        "$CLOUDFORMATION_DIR/public-ip.yml"
        "$CLOUDFORMATION_DIR/http-validation-ingress.yml"
        "$CLOUDFORMATION_DIR/mysql-storage.yml"
        "$CLOUDFORMATION_DIR/runtime-secrets.yml"
        "$CLOUDFORMATION_DIR/system-alerts.yml"
    )

    require_command cfn-lint
    require_command ansible
    require_command docker
    require_command jq
    require_command sha256sum

    "$REPOSITORY_DIR/scripts/validate-environments.sh"
    "$PROD_DIR/scripts/test-morrowpal-service.sh"
    "$PROD_DIR/scripts/test-morrowpal-deploy-release.sh"
    "$PROD_DIR/scripts/test-morrowpal-app-website-releases.sh"
    "$PROD_DIR/scripts/test-morrowpal-publishers.sh"
    "$PROD_DIR/scripts/test-morrowpal-rate-limit-verifiers.sh"
    "$PROD_DIR/scripts/test-morrowpal-tls-templates.sh"
    "$PROD_DIR/scripts/test-morrowpal-nginx-templates.sh"

    docker compose version >/dev/null 2>&1 \
        || fail "Docker Compose plugin is not available"

    printf 'Linting %d CloudFormation templates for %s...\n' \
        "${#templates[@]}" "$AWS_REGION"
    cfn-lint \
        --format json \
        --regions "$AWS_REGION" \
        -t "${templates[@]}"

    [[ -f "$COMPOSE_BASELINE_FILE" ]] \
        || fail "Compose baseline not found: $COMPOSE_BASELINE_FILE"
    IFS= read -r expected_digest <"$COMPOSE_BASELINE_FILE" \
        || fail "Could not read Compose baseline: $COMPOSE_BASELINE_FILE"
    [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] \
        || fail "Compose baseline must contain one lowercase SHA-256 digest"

    [[ -f "$ENVOY_BASELINE_FILE" ]] \
        || fail "Envoy baseline not found: $ENVOY_BASELINE_FILE"
    IFS= read -r envoy_expected_digest <"$ENVOY_BASELINE_FILE" \
        || fail "Could not read Envoy baseline: $ENVOY_BASELINE_FILE"
    [[ "$envoy_expected_digest" =~ ^[0-9a-f]{64}$ ]] \
        || fail "Envoy baseline must contain one lowercase SHA-256 digest"

    prod_compose_env_file="$(mktemp)"
    staging_compose_env_file="$(mktemp)"
    prod_envoy_file="$(mktemp)"
    staging_envoy_file="$(mktemp)"
    printf -v cleanup_command \
        'rm -f -- %q %q %q %q' \
        "$prod_compose_env_file" \
        "$staging_compose_env_file" \
        "$prod_envoy_file" \
        "$staging_envoy_file"
    trap "$cleanup_command" EXIT

    render_compose_environment prod "$prod_compose_env_file"
    render_compose_environment staging "$staging_compose_env_file"
    render_envoy_environment prod "$prod_envoy_file"
    render_envoy_environment staging "$staging_envoy_file"

    printf 'Comparing rendered production Envoy configuration to its baseline...\n'
    digest_output="$(sha256sum "$prod_envoy_file")"
    envoy_actual_digest="${digest_output%% *}"
    [[ "$envoy_actual_digest" == "$envoy_expected_digest" ]] \
        || fail "Rendered production Envoy configuration changed"

    grep -Fqx '  id: morrowpal-staging-envoy' "$staging_envoy_file" \
        || fail "Staging Envoy node ID is incorrect"
    grep -Fqx '  cluster: morrowpal-staging' "$staging_envoy_file" \
        || fail "Staging Envoy cluster is incorrect"
    for expected_staging_value in \
        '                    - name: staging_api' \
        '                        - api.staging.morrowpal.com' \
        '                    - name: staging_app' \
        '                        - app.staging.morrowpal.com' \
        '                    - name: staging_website' \
        '                        - staging.morrowpal.com' \
        '                    - name: staging_website_redirect' \
        '                        - www.staging.morrowpal.com' \
        '                            host_redirect: staging.morrowpal.com' \
        '                    - name: reserved_staging_names' \
        '                        - admin.staging.morrowpal.com' \
        '                        - back.staging.morrowpal.com'; do
        grep -Fqx "$expected_staging_value" "$staging_envoy_file" \
            || fail "Staging Envoy rendering is missing: $expected_staging_value"
    done
    if grep -Eq 'morrowpal-prod|(^|[[:space:]])(api\.|app\.|www\.|admin\.|back\.)?morrowpal\.com([[:space:]]|$)' \
            "$staging_envoy_file"; then
        fail "Staging Envoy rendering contains a production identity or hostname"
    fi

    printf 'Rendering production and staging Compose configurations...\n'
    prod_render="$(render_compose "$prod_compose_env_file")"
    staging_render="$(render_compose "$staging_compose_env_file")"

    printf 'Comparing the rendered production Compose configuration to its baseline...\n'
    digest_output="$(jq --sort-keys --compact-output . <<<"$prod_render" | sha256sum)"
    actual_digest="${digest_output%% *}"

    if [[ "$actual_digest" != "$expected_digest" ]]; then
        printf 'Error: Rendered production Compose configuration changed.\n' >&2
        printf 'Expected: %s\n' "$expected_digest" >&2
        printf 'Actual:   %s\n' "$actual_digest" >&2
        printf 'Review the rendered Compose diff before updating the baseline.\n' >&2
        exit 1
    fi

    [[ "$(jq --compact-output '.services | keys' <<<"$prod_render")" == \
        "$(jq --compact-output '.services | keys' <<<"$staging_render")" ]] \
        || fail "Production and staging Compose service topology differs"

    jq --exit-status '
        ([
            (.services["backend-api-blue"].image | startswith("384078510608.dkr.ecr.us-east-2.amazonaws.com/morrowpal/staging/backend-api:")),
            (.services["backend-api-green"].image | startswith("384078510608.dkr.ecr.us-east-2.amazonaws.com/morrowpal/staging/backend-api:")),
            (.services["backend-job-dispatch"].image | startswith("384078510608.dkr.ecr.us-east-2.amazonaws.com/morrowpal/staging/backend-job:")),
            (.services["backend-job-cleanup"].image | startswith("384078510608.dkr.ecr.us-east-2.amazonaws.com/morrowpal/staging/backend-job:")),
            (.services.app.image | startswith("384078510608.dkr.ecr.us-east-2.amazonaws.com/morrowpal/staging/app:")),
            (.services.website.image | startswith("384078510608.dkr.ecr.us-east-2.amazonaws.com/morrowpal/staging/website:"))
        ] | all) and
        .services["backend-api-blue"].environment.AWS_REGION == "us-east-2" and
        .services["backend-api-blue"].environment.APP_AUTH_STORE_REVIEW_EMAIL == "store-review@staging.morrowpal.com" and
        .services["backend-api-blue"].environment.APP_API_CORS_ALLOWED_ORIGIN_PATTERNS == "https://app.staging.morrowpal.com,https://staging.morrowpal.com" and
        .services["backend-api-blue"].environment.APP_CLIENT_COMPATIBILITY_WEB_UPDATE_URL == "https://app.staging.morrowpal.com/" and
        .services["backend-job-dispatch"].environment.APP_APP_NOTIFICATIONS_PROVIDER == "stub" and
        .services["backend-job-dispatch"].environment.APP_APP_NOTIFICATIONS_FIREBASE_PROJECT_ID == "STAGING_FIREBASE_PROJECT_ID" and
        .services["backend-job-dispatch"].environment.APP_SYSTEM_ALERTS_TOPIC_ARN == "arn:aws:sns:us-east-2:384078510608:morrowpal-staging-system-alerts" and
        .services["backend-job-dispatch"].environment.APP_EMAIL_POSTMARK_DISPATCH_FROM_ADDRESS == "MorrowPal <notifications@staging.morrowpal.com>" and
        .services["backend-job-dispatch"].environment.APP_EMAIL_DISPATCH_OPT_OUT_URL == "https://staging.morrowpal.com/notifications/disable/" and
        .services["backend-api-blue"].environment.APP_EMAIL_POSTMARK_OTP_FROM_ADDRESS == "MorrowPal <verification-code@staging.morrowpal.com>" and
        (.services.envoy.volumes | any(
            .source == "/etc/letsencrypt/live/staging.morrowpal.com" and
            .target == "/etc/letsencrypt/live/staging.morrowpal.com"
        )) and
        (.services.envoy.volumes | any(
            .source == "/etc/letsencrypt/archive/staging.morrowpal.com" and
            .target == "/etc/letsencrypt/archive/staging.morrowpal.com"
        ))
    ' <<<"$staging_render" >/dev/null \
        || fail "Staging Compose rendering is missing an isolated environment value"

    for forbidden_value in \
        'morrowpal/prod/' \
        'morrowpal-prod-system-alerts' \
        'store-review@morrowpal.com' \
        'verification-code@morrowpal.com' \
        'notifications@morrowpal.com' \
        'https://app.morrowpal.com' \
        'https://morrowpal.com' \
        '/etc/letsencrypt/live/morrowpal.com' \
        '/etc/letsencrypt/archive/morrowpal.com'; do
        [[ "$staging_render" != *"$forbidden_value"* ]] \
            || fail "Staging Compose rendering contains production value: $forbidden_value"
    done

    printf 'Local infrastructure validation passed.\n'
}

main "$@"
