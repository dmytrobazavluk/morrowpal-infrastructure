#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROD_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CLOUDFORMATION_DIR="$PROD_DIR/cloudformation"
readonly COMPOSE_BASELINE_FILE="$PROD_DIR/baselines/docker-compose-production.sha256"
readonly AWS_REGION="us-east-2"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

render_compose() {
    env \
        API_BLUE_IMAGE_TAG=validation \
        API_GREEN_IMAGE_TAG=validation \
        JOB_IMAGE_TAG=validation \
        APP_IMAGE_TAG=validation \
        WEBSITE_IMAGE_TAG=validation \
        docker compose \
            --project-directory "$PROD_DIR" \
            --file "$PROD_DIR/docker-compose.yml" \
            config --format json
}

main() {
    local actual_digest
    local digest_output
    local expected_digest
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
    require_command docker
    require_command jq
    require_command sha256sum

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

    printf 'Comparing the rendered production Compose configuration to its baseline...\n'
    digest_output="$(render_compose | jq --sort-keys --compact-output . | sha256sum)"
    actual_digest="${digest_output%% *}"

    if [[ "$actual_digest" != "$expected_digest" ]]; then
        printf 'Error: Rendered production Compose configuration changed.\n' >&2
        printf 'Expected: %s\n' "$expected_digest" >&2
        printf 'Actual:   %s\n' "$actual_digest" >&2
        printf 'Review the rendered Compose diff before updating the baseline.\n' >&2
        exit 1
    fi

    printf 'Local infrastructure validation passed.\n'
}

main "$@"
