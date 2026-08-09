#!/usr/bin/env bash

set -Eeuo pipefail

readonly registry=384078510608.dkr.ecr.us-east-2.amazonaws.com
readonly aws_region=us-east-2
readonly deployment_root=/opt/morrowpal
readonly compose_file="$deployment_root/docker-compose.yml"
readonly blue_tag_file="$deployment_root/api-blue-image-tag"
readonly green_tag_file="$deployment_root/api-green-image-tag"
readonly job_tag_file="$deployment_root/job-image-tag"
readonly app_tag_file="$deployment_root/app-image-tag"
readonly deployment_lock=/run/morrowpal-deploy.lock

new_tag="${1:-}"
[[ "$new_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || {
    printf 'Usage: %s build-N-GITSHA\n' "$0" >&2
    exit 2
}

exec 9>"$deployment_lock"
flock --exclusive --nonblock 9 || {
    printf 'Another MorrowPal deployment is already running.\n' >&2
    exit 1
}

systemctl is-active --quiet morrowpal.service || {
    printf 'morrowpal.service must be active before an app deployment.\n' >&2
    exit 1
}

for tag_file in "$blue_tag_file" "$green_tag_file" "$job_tag_file" "$app_tag_file"; do
    [[ -r "$tag_file" ]] || {
        printf 'Required tag file is missing: %s\n' "$tag_file" >&2
        exit 1
    }
done

blue_tag="$(<"$blue_tag_file")"
green_tag="$(<"$green_tag_file")"
job_tag="$(<"$job_tag_file")"
old_tag="$(<"$app_tag_file")"
app_tag="$old_tag"

compose() {
    API_BLUE_IMAGE_TAG="$blue_tag" \
    API_GREEN_IMAGE_TAG="$green_tag" \
    JOB_IMAGE_TAG="$job_tag" \
    APP_IMAGE_TAG="$app_tag" \
        docker compose \
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

wait_for_app() {
    local container_id
    local status

    for _ in {1..30}; do
        container_id="$(compose ps -q app)"
        if [[ -n "$container_id" ]]; then
            status="$(docker inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
            if [[ "$status" == healthy ]] && \
                    curl --fail --silent --show-error \
                        --resolve app.morrowpal.com:443:127.0.0.1 \
                        https://app.morrowpal.com/ready >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

if [[ "$old_tag" == "$new_tag" ]]; then
    printf 'App %s is already deployed.\n' "$new_tag"
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

app_tag="$new_tag"
compose pull app

if compose up --detach --no-deps app && wait_for_app; then
    write_tag "$app_tag_file" "$new_tag"
    docker logout "$registry" >/dev/null 2>&1
    logged_in=false
    compose ps app
    exit 0
fi

printf 'App failed readiness; restoring %s.\n' "$old_tag" >&2
app_tag="$old_tag"
compose up --detach --no-deps app
wait_for_app
exit 1
