#!/usr/bin/env bash

set -Eeuo pipefail

readonly aws_region=us-east-2
readonly registry=384078510608.dkr.ecr.us-east-2.amazonaws.com
readonly deployment_root=/opt/morrowpal
readonly compose_file="$deployment_root/docker-compose.yml"
readonly blue_tag_file="$deployment_root/api-blue-image-tag"
readonly green_tag_file="$deployment_root/api-green-image-tag"
readonly job_tag_file="$deployment_root/job-image-tag"
readonly app_tag_file="$deployment_root/app-image-tag"

for tag_file in "$blue_tag_file" "$green_tag_file" "$job_tag_file" "$app_tag_file"; do
    [[ -r "$tag_file" ]] || {
        printf 'Image tag file is missing: %s\n' "$tag_file" >&2
        exit 1
    }
done

blue_tag="$(<"$blue_tag_file")"
green_tag="$(<"$green_tag_file")"
job_tag="$(<"$job_tag_file")"
app_tag="$(<"$app_tag_file")"
for image_tag in "$blue_tag" "$green_tag" "$job_tag" "$app_tag"; do
    [[ "$image_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || {
        printf 'Invalid image tag: %s\n' "$image_tag" >&2
        exit 1
    }
done

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

action="${1:-start}"
recreate_envoy=false

case "$action" in
    stop)
        compose down --remove-orphans
        rm -rf /run/morrowpal/secrets
        exit 0
        ;;
    status)
        compose ps
        curl --fail --silent --show-error http://127.0.0.1:8080/ready
        printf '\n'
        exit 0
        ;;
    start)
        ;;
    reconcile)
        case "${2:-}" in
            "")
                ;;
            --recreate-envoy)
                recreate_envoy=true
                ;;
            *)
                printf 'Usage: %s reconcile [--recreate-envoy]\n' "$0" >&2
                exit 2
                ;;
        esac
        exec 9>/run/morrowpal-deploy.lock
        flock --exclusive --nonblock 9 || {
            printf 'Another MorrowPal deployment is already running.\n' >&2
            exit 1
        }
        systemctl is-active --quiet morrowpal.service || {
            printf 'morrowpal.service must be active before reconciliation.\n' >&2
            exit 1
        }
        ;;
    *)
        printf 'Usage: %s [start|stop|status|reconcile [--recreate-envoy]]\n' "$0" >&2
        exit 2
        ;;
esac

wait_for_mysql() {
    local mysql_container_id
    local mysql_status=""

    for _ in {1..60}; do
        mysql_container_id="$(compose ps -q mysql)"
        if [[ -n "$mysql_container_id" ]]; then
            mysql_status="$(docker inspect --format '{{.State.Health.Status}}' "$mysql_container_id" 2>/dev/null || true)"
        fi
        [[ "$mysql_status" == healthy ]] && return 0
        sleep 5
    done

    printf 'MySQL did not become healthy. Last status: %s\n' "$mysql_status" >&2
    return 1
}

wait_for_api() {
    for _ in {1..60}; do
        if curl --fail --silent --show-error http://127.0.0.1:8080/ready >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done

    printf 'Envoy did not find a ready backend API.\n' >&2
    return 1
}

wait_for_app() {
    for _ in {1..30}; do
        if curl --fail --silent --show-error \
                --resolve app.morrowpal.com:443:127.0.0.1 \
                https://app.morrowpal.com/ready >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    printf 'Envoy did not find a ready app.\n' >&2
    return 1
}

logged_in=false
cleanup() {
    if [[ "$logged_in" == true ]]; then
        docker logout "$registry" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

export AWS_REGION="$aws_region"
export MYSQL_APP_PASSWORD='{{resolve:secretsmanager:morrowpal/prod/mysql:SecretString:password}}'
export MYSQL_ROOT_PASSWORD='{{resolve:secretsmanager:morrowpal/prod/mysql-root:SecretString:password}}'
export JWT_SIGNING_SECRET='{{resolve:secretsmanager:morrowpal/prod/jwt:SecretString:value}}'

secrets_resolved=false
for _ in {1..6}; do
    if /usr/local/bin/asm-exec -- /usr/local/libexec/morrowpal/write-runtime-secrets; then
        secrets_resolved=true
        break
    fi
    sleep 10
done
[[ "$secrets_resolved" == true ]] || {
    printf 'Runtime secrets could not be resolved after six attempts.\n' >&2
    exit 1
}

unset MYSQL_APP_PASSWORD MYSQL_ROOT_PASSWORD JWT_SIGNING_SECRET

aws ecr get-login-password --region "$aws_region" \
    | docker login --username AWS --password-stdin "$registry"
logged_in=true

compose pull
docker logout "$registry" >/dev/null 2>&1
logged_in=false

if [[ "$action" == reconcile ]]; then
    compose up --detach --remove-orphans --wait --wait-timeout 300
    if [[ "$recreate_envoy" == true ]]; then
        compose up --detach --no-deps --force-recreate envoy
    fi
    wait_for_mysql
    wait_for_api
    wait_for_app
    compose ps
    exit 0
fi

compose up -d --remove-orphans mysql
wait_for_mysql

compose up -d app backend-api-blue backend-api-green envoy
wait_for_api
wait_for_app

compose up -d backend-job-dispatch backend-job-cleanup
compose ps
