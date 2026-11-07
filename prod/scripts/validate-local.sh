#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROD_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CLOUDFORMATION_DIR="$PROD_DIR/cloudformation"
readonly AWS_REGION="us-east-2"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

main() {
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

    docker compose version >/dev/null 2>&1 \
        || fail "Docker Compose plugin is not available"

    printf 'Linting %d CloudFormation templates for %s...\n' \
        "${#templates[@]}" "$AWS_REGION"
    cfn-lint \
        --format json \
        --regions "$AWS_REGION" \
        -t "${templates[@]}"

    printf 'Rendering the production Docker Compose configuration...\n'
    env \
        API_BLUE_IMAGE_TAG=validation \
        API_GREEN_IMAGE_TAG=validation \
        JOB_IMAGE_TAG=validation \
        APP_IMAGE_TAG=validation \
        WEBSITE_IMAGE_TAG=validation \
        docker compose \
            --project-directory "$PROD_DIR" \
            --file "$PROD_DIR/docker-compose.yml" \
            config >/dev/null

    printf 'Local infrastructure validation passed.\n'
}

main "$@"
