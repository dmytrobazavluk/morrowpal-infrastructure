#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SHARED_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_DIR="$(cd -- "$SHARED_DIR/.." && pwd)"
readonly PROD_DIR="$REPOSITORY_DIR/prod"
readonly CLOUDFORMATION_DIR="$REPOSITORY_DIR/shared/cloudformation"
readonly COMPOSE_BASELINE_FILE="$PROD_DIR/baselines/docker-compose-production.sha256"
readonly COMPOSE_ENV_TEMPLATE="$SHARED_DIR/runtime/compose.env.j2"
readonly ENVOY_BASELINE_FILE="$PROD_DIR/baselines/envoy-production.sha256"
readonly ENVOY_TEMPLATE="$SHARED_DIR/runtime/envoy/envoy.yaml.j2"

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

read_rendered_environment_value() {
    local environment_file="$1"
    local variable_name="$2"

    (
        # shellcheck source=/dev/null
        source "$environment_file"
        printf '%s' "${!variable_name}"
    )
}

reject_environment_default() {
    local template="$1"

    if awk '
        /^  Environment:$/ {
            in_environment = 1
            next
        }
        in_environment && /^  [[:alnum:]_]+:$/ {
            in_environment = 0
        }
        in_environment && /^[[:space:]]+Default:/ {
            found_default = 1
        }
        END {
            exit found_default ? 0 : 1
        }
    ' "$template"; then
        fail "Environment parameter must not have a default: ${template#$REPOSITORY_DIR/}"
    fi
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
    local staging_aws_region
    local staging_ecr_registry
    local staging_ecr_repository_prefix
    local staging_render
    local staging_envoy_file
    local staging_system_alerts_topic_arn
    local template
    local -a aws_regions=()
    local -a templates=(
        "$CLOUDFORMATION_DIR/prerequisites.yml"
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
    "$SCRIPT_DIR/test-morrowpal-service.sh"
    "$SCRIPT_DIR/test-morrowpal-deploy-release.sh"
    "$SCRIPT_DIR/test-morrowpal-app-website-releases.sh"
    "$SCRIPT_DIR/test-morrowpal-images.sh"
    bash "$SCRIPT_DIR/test-staging-lifecycle.sh"
    "$SCRIPT_DIR/test-morrowpal-infrastructure-change-set.sh"
    "$SCRIPT_DIR/test-morrowpal-rate-limit-verifiers.sh"
    "$SCRIPT_DIR/test-morrowpal-tls-templates.sh"
    "$SCRIPT_DIR/test-morrowpal-nginx-templates.sh"
    bash "$SCRIPT_DIR/test-morrowpal-web-runtime.sh"

    docker compose version >/dev/null 2>&1 \
        || fail "Docker Compose plugin is not available"

    mapfile -t aws_regions < <(
        awk '$1 == "morrowpal_aws_region:" { print $2 }' \
            "$REPOSITORY_DIR/environments/prod/vars.yml" \
            "$REPOSITORY_DIR/environments/staging/vars.yml" \
            | sort --unique
    )
    ((${#aws_regions[@]} > 0)) \
        || fail "No environment AWS Regions were configured"

    printf 'Linting %d CloudFormation templates for: %s...\n' \
        "${#templates[@]}" "${aws_regions[*]}"
    for template in "${templates[@]}"; do
        reject_environment_default "$template"
    done
    cfn-lint \
        --format json \
        --regions "${aws_regions[@]}" \
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
    staging_aws_region="$(read_rendered_environment_value \
        "$staging_compose_env_file" MORROWPAL_AWS_REGION)"
    staging_ecr_registry="$(read_rendered_environment_value \
        "$staging_compose_env_file" MORROWPAL_ECR_REGISTRY)"
    staging_ecr_repository_prefix="$(read_rendered_environment_value \
        "$staging_compose_env_file" MORROWPAL_ECR_REPOSITORY_PREFIX)"
    staging_system_alerts_topic_arn="$(read_rendered_environment_value \
        "$staging_compose_env_file" MORROWPAL_SYSTEM_ALERTS_TOPIC_ARN)"

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
    # Keep the captured production baseline. Validate the shared MySQL pin and
    # app runtime mount explicitly, then normalize those reviewed differences.
    jq --exit-status '.services.mysql.image | test("^mysql:8\\.4\\.[0-9]+@sha256:[0-9a-f]{64}$")' \
        <<<"$prod_render" >/dev/null || fail "MySQL must pin an 8.4 patch version and digest"
    [[ "$(jq --raw-output '.services.mysql.image' <<<"$prod_render")" == \
        "$(jq --raw-output '.services.mysql.image' <<<"$staging_render")" ]] \
        || fail "MySQL image differs between environment renderings"
    jq --exit-status '.services.app.volumes | any(.target == "/etc/morrowpal/runtime-config.js" and .read_only == true)' \
        <<<"$prod_render" >/dev/null || fail "App runtime configuration mount must be read-only"
    digest_output="$(jq --sort-keys --compact-output \
        '.services.mysql.image = "mysql:8.4" |
         .services.app.volumes |= map(select(.target != "/etc/morrowpal/runtime-config.js"))' \
        <<<"$prod_render" | sha256sum)"
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

    jq --exit-status \
        --arg aws_region "$staging_aws_region" \
        --arg ecr_registry "$staging_ecr_registry" \
        --arg ecr_repository_prefix "$staging_ecr_repository_prefix" \
        --arg system_alerts_topic_arn "$staging_system_alerts_topic_arn" '
        ([
            (.services["backend-api-blue"].image | startswith($ecr_registry + "/" + $ecr_repository_prefix + "/backend-api:")),
            (.services["backend-api-green"].image | startswith($ecr_registry + "/" + $ecr_repository_prefix + "/backend-api:")),
            (.services["backend-job-dispatch"].image | startswith($ecr_registry + "/" + $ecr_repository_prefix + "/backend-job:")),
            (.services["backend-job-cleanup"].image | startswith($ecr_registry + "/" + $ecr_repository_prefix + "/backend-job:")),
            (.services.app.image | startswith($ecr_registry + "/" + $ecr_repository_prefix + "/app:")),
            (.services.website.image | startswith($ecr_registry + "/" + $ecr_repository_prefix + "/website:"))
        ] | all) and
        .services["backend-api-blue"].environment.AWS_REGION == $aws_region and
        .services["backend-api-blue"].environment.APP_AUTH_STORE_REVIEW_EMAIL == "store-review@staging.morrowpal.com" and
        .services["backend-api-blue"].environment.APP_API_CORS_ALLOWED_ORIGIN_PATTERNS == "https://app.staging.morrowpal.com,https://staging.morrowpal.com" and
        .services["backend-api-blue"].environment.APP_CLIENT_COMPATIBILITY_WEB_UPDATE_URL == "https://app.staging.morrowpal.com/" and
        .services["backend-job-dispatch"].environment.APP_APP_NOTIFICATIONS_PROVIDER == "firebase" and
        .services["backend-job-dispatch"].environment.APP_APP_NOTIFICATIONS_FIREBASE_PROJECT_ID == "morrowpal-staging" and
        .services["backend-job-dispatch"].environment.APP_SYSTEM_ALERTS_TOPIC_ARN == $system_alerts_topic_arn and
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
