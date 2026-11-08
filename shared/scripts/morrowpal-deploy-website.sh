#!/usr/bin/env bash

set -Eeuo pipefail

readonly environment_file="${MORROWPAL_ENVIRONMENT_FILE:-/etc/morrowpal/environment}"
readonly runtime_config_library="${MORROWPAL_RUNTIME_CONFIG_LIBRARY:-/usr/local/libexec/morrowpal/runtime-config}"

[[ -r "$environment_file" ]] || {
    printf 'Environment configuration is missing: %s\n' "$environment_file" >&2
    exit 1
}
[[ -r "$runtime_config_library" ]] || {
    printf 'Runtime configuration library is missing: %s\n' "$runtime_config_library" >&2
    exit 1
}

set -a
# shellcheck source=/dev/null
source "$environment_file"
set +a
# shellcheck source=morrowpal-runtime-config.sh
source "$runtime_config_library"

readonly -a required_environment_variables=(
    MORROWPAL_AWS_REGION
    MORROWPAL_ECR_REGISTRY
    MORROWPAL_ECR_REPOSITORY_PREFIX
    MORROWPAL_DEPLOYMENT_ROOT
    MORROWPAL_WEBSITE_DOMAIN
)
morrowpal_require_environment_values "${required_environment_variables[@]}"

readonly registry="$MORROWPAL_ECR_REGISTRY"
readonly aws_region="$MORROWPAL_AWS_REGION"
readonly deployment_root="$MORROWPAL_DEPLOYMENT_ROOT"
readonly website_domain="$MORROWPAL_WEBSITE_DOMAIN"
readonly compose_file="$deployment_root/docker-compose.yml"
readonly blue_tag_file="$deployment_root/api-blue-image-tag"
readonly green_tag_file="$deployment_root/api-green-image-tag"
readonly job_tag_file="$deployment_root/job-image-tag"
readonly app_tag_file="$deployment_root/app-image-tag"
readonly website_tag_file="$deployment_root/website-image-tag"
readonly deployment_lock="${MORROWPAL_DEPLOYMENT_LOCK:-/run/morrowpal-deploy.lock}"

new_tag="${1:-}"
[[ "$new_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || {
    printf 'Usage: %s build-N-SOURCESHA\n' "$0" >&2
    exit 2
}

exec 9>"$deployment_lock"
flock --exclusive --nonblock 9 || {
    printf 'Another MorrowPal deployment is already running.\n' >&2
    exit 1
}

systemctl is-active --quiet morrowpal.service || {
    printf 'morrowpal.service must be active before a website deployment.\n' >&2
    exit 1
}

for tag_file in "$blue_tag_file" "$green_tag_file" "$job_tag_file" "$app_tag_file" "$website_tag_file"; do
    [[ -r "$tag_file" ]] || {
        printf 'Required tag file is missing: %s\n' "$tag_file" >&2
        exit 1
    }
done

blue_tag="$(<"$blue_tag_file")"
green_tag="$(<"$green_tag_file")"
job_tag="$(<"$job_tag_file")"
app_tag="$(<"$app_tag_file")"
old_tag="$(<"$website_tag_file")"
website_tag="$old_tag"

compose() {
    API_BLUE_IMAGE_TAG="$blue_tag" \
    API_GREEN_IMAGE_TAG="$green_tag" \
    JOB_IMAGE_TAG="$job_tag" \
    APP_IMAGE_TAG="$app_tag" \
    WEBSITE_IMAGE_TAG="$website_tag" \
        docker compose \
            --env-file "$environment_file" \
            --project-directory "$deployment_root" \
            --file "$compose_file" \
            "$@"
}

write_tag() {
    local destination="$1"
    local value="$2"
    local temporary_file

    temporary_file="$(mktemp "$deployment_root/.image-tag.XXXXXX")"
    printf '%s\n' "$value" >"$temporary_file"
    chown root:root "$temporary_file"
    chmod 0640 "$temporary_file"
    mv -f "$temporary_file" "$destination"
}

wait_for_website() {
    local container_id
    local status

    for _ in {1..30}; do
        container_id="$(compose ps -q website)"
        if [[ -n "$container_id" ]]; then
            status="$(docker inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
            if [[ "$status" == healthy ]] && \
                    curl --fail --silent --show-error \
                        --resolve "${website_domain}:443:127.0.0.1" \
                        "https://${website_domain}/ready" >/dev/null 2>&1 && \
                    curl --fail --silent --show-error \
                        --resolve "${website_domain}:443:127.0.0.1" \
                        "https://${website_domain}/" >/dev/null 2>&1 && \
                    curl --fail --silent --show-error \
                        --resolve "${website_domain}:443:127.0.0.1" \
                        "https://${website_domain}/child-safety/" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

if [[ "$old_tag" == "$new_tag" ]]; then
    printf 'Website %s is already deployed.\n' "$new_tag"
    exit 0
fi

logged_in=false
cleanup() {
    if [[ "$logged_in" == true ]]; then
        docker logout "$registry" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

aws ecr get-login-password --region "$aws_region" \
    | docker login --username AWS --password-stdin "$registry"
logged_in=true

website_tag="$new_tag"
compose pull website

if compose up --detach --no-deps website && wait_for_website; then
    write_tag "$website_tag_file" "$new_tag"
    docker logout "$registry" >/dev/null 2>&1
    logged_in=false
    compose ps website
    exit 0
fi

printf 'Website failed readiness; restoring %s.\n' "$old_tag" >&2
website_tag="$old_tag"
compose up --detach --no-deps website
wait_for_website
exit 1
