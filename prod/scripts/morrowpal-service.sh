#!/usr/bin/env bash

set -Eeuo pipefail

readonly aws_region=us-east-2
readonly registry=384078510608.dkr.ecr.us-east-2.amazonaws.com
readonly deployment_root=/opt/morrowpal
readonly compose_file="$deployment_root/docker-compose.yml"
readonly blue_tag_file="$deployment_root/api-blue-image-tag"
readonly green_tag_file="$deployment_root/api-green-image-tag"
readonly job_tag_file="$deployment_root/job-image-tag"

for tag_file in "$blue_tag_file" "$green_tag_file" "$job_tag_file"; do
    [[ -r "$tag_file" ]] || {
        printf 'Image tag file is missing: %s\n' "$tag_file" >&2
        exit 1
    }
done

blue_tag="$(<"$blue_tag_file")"
green_tag="$(<"$green_tag_file")"
job_tag="$(<"$job_tag_file")"
for image_tag in "$blue_tag" "$green_tag" "$job_tag"; do
    [[ "$image_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || {
        printf 'Invalid image tag: %s\n' "$image_tag" >&2
        exit 1
    }
done

compose() {
    API_BLUE_IMAGE_TAG="$blue_tag" \
    API_GREEN_IMAGE_TAG="$green_tag" \
    JOB_IMAGE_TAG="$job_tag" \
        docker compose \
        --project-directory "$deployment_root" \
        --file "$compose_file" \
        "$@"
}

case "${1:-start}" in
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
    *)
        printf 'Usage: %s [start|stop|status]\n' "$0" >&2
        exit 2
        ;;
esac

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

compose up -d --remove-orphans mysql

mysql_status=""
for _ in {1..60}; do
    mysql_container_id="$(compose ps -q mysql)"
    mysql_status="$(docker inspect --format '{{.State.Health.Status}}' "$mysql_container_id" 2>/dev/null || true)"
    [[ "$mysql_status" == healthy ]] && break
    sleep 5
done
[[ "$mysql_status" == healthy ]] || {
    printf 'MySQL did not become healthy. Last status: %s\n' "$mysql_status" >&2
    exit 1
}

compose up -d backend-api-blue backend-api-green envoy

api_ready=false
for _ in {1..60}; do
    if curl --fail --silent --show-error http://127.0.0.1:8080/ready >/dev/null 2>&1; then
        api_ready=true
        break
    fi
    sleep 5
done
[[ "$api_ready" == true ]] || {
    printf 'Envoy did not find a ready backend API.\n' >&2
    exit 1
}

compose up -d backend-job-dispatch backend-job-cleanup
compose ps
