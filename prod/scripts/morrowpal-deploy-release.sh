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
readonly envoy_admin=http://127.0.0.1:9901
readonly deployment_lock=/run/morrowpal-deploy.lock

force_recreate=false
if [[ "${1:-}" == --force-recreate ]]; then
    force_recreate=true
    shift
fi

requested_tag="${1:-}"
[[ -z "$requested_tag" || "$requested_tag" =~ ^build-[1-9][0-9]*-[0-9a-f]{7}$ ]] || {
    printf 'Usage: %s [--force-recreate] [build-N-GITSHA]\n' "$0" >&2
    exit 2
}
[[ "$force_recreate" == true || -n "$requested_tag" ]] || {
    printf 'Usage: %s [--force-recreate] [build-N-GITSHA]\n' "$0" >&2
    exit 2
}
[[ $# -le 1 ]] || {
    printf 'Usage: %s [--force-recreate] [build-N-GITSHA]\n' "$0" >&2
    exit 2
}

exec 9>"$deployment_lock"
flock --exclusive --nonblock 9 || {
    printf 'Another MorrowPal deployment is already running.\n' >&2
    exit 1
}

systemctl is-active --quiet morrowpal.service || {
    printf 'morrowpal.service must be active before a rolling deployment.\n' >&2
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
app_tag="$(<"$app_tag_file")"

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

set_weights() {
    local blue_weight="$1"
    local green_weight="$2"

    curl --fail --silent --show-error \
        --request POST \
        "$envoy_admin/runtime_modify?routing.backend_api.backend_api_blue=$blue_weight&routing.backend_api.backend_api_green=$green_weight" \
        >/dev/null
}

wait_for_container_ready() {
    local service="$1"
    local container_id
    local container_ip

    for _ in {1..60}; do
        container_id="$(compose ps -q "$service")"
        if [[ -n "$container_id" ]]; then
            container_ip="$(docker inspect --format '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_id")"
            if [[ -n "$container_ip" ]] && \
                    curl --fail --silent --show-error "http://$container_ip:8080/ready" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

wait_for_cluster_drained() {
    local cluster="$1"
    local active_requests

    for _ in {1..60}; do
        active_requests="$(
            curl --fail --silent --show-error \
                "$envoy_admin/stats?filter=^cluster\\.$cluster\\.upstream_rq_active$&format=json" |
                python3 -c 'import json,sys; stats=json.load(sys.stdin).get("stats", []); print(stats[0].get("value", 0) if stats else 0)'
        )"
        [[ "$active_requests" == 0 ]] && return 0
        sleep 1
    done
    return 1
}

deploy_api_slot() {
    local slot="$1"
    local service="backend-api-$slot"
    local old_tag
    local target_tag
    local other_service
    local drained_cluster

    if [[ "$slot" == blue ]]; then
        old_tag="$blue_tag"
        other_service=backend-api-green
        drained_cluster=backend_api_blue
        target_tag="${requested_tag:-$old_tag}"
        [[ "$old_tag" == "$target_tag" && "$force_recreate" == false ]] && return 0
        if ! wait_for_container_ready "$other_service"; then
            printf 'The green API is not ready; refusing to replace blue.\n' >&2
            return 1
        fi
        printf 'Rolling blue API from %s to %s.\n' "$old_tag" "$target_tag"
        API_BLUE_IMAGE_TAG="$target_tag" API_GREEN_IMAGE_TAG="$green_tag" \
            JOB_IMAGE_TAG="$job_tag" APP_IMAGE_TAG="$app_tag" \
            docker compose --project-directory "$deployment_root" --file "$compose_file" pull "$service"
        set_weights 0 100
        if ! wait_for_cluster_drained "$drained_cluster"; then
            printf 'The blue API did not drain; restoring balanced traffic.\n' >&2
            set_weights 50 50
            return 1
        fi
        blue_tag="$target_tag"
    else
        old_tag="$green_tag"
        other_service=backend-api-blue
        drained_cluster=backend_api_green
        target_tag="${requested_tag:-$old_tag}"
        [[ "$old_tag" == "$target_tag" && "$force_recreate" == false ]] && return 0
        if ! wait_for_container_ready "$other_service"; then
            printf 'The blue API is not ready; refusing to replace green.\n' >&2
            return 1
        fi
        printf 'Rolling green API from %s to %s.\n' "$old_tag" "$target_tag"
        API_BLUE_IMAGE_TAG="$blue_tag" API_GREEN_IMAGE_TAG="$target_tag" \
            JOB_IMAGE_TAG="$job_tag" APP_IMAGE_TAG="$app_tag" \
            docker compose --project-directory "$deployment_root" --file "$compose_file" pull "$service"
        set_weights 100 0
        if ! wait_for_cluster_drained "$drained_cluster"; then
            printf 'The green API did not drain; restoring balanced traffic.\n' >&2
            set_weights 50 50
            return 1
        fi
        green_tag="$target_tag"
    fi

    if compose up --detach --no-deps --force-recreate "$service" && wait_for_container_ready "$service"; then
        if [[ "$slot" == blue ]]; then
            write_tag "$blue_tag_file" "$target_tag"
        else
            write_tag "$green_tag_file" "$target_tag"
        fi
        set_weights 50 50
        return 0
    fi

    printf 'The %s API failed readiness; restoring %s.\n' "$slot" "$old_tag" >&2
    if [[ "$slot" == blue ]]; then
        blue_tag="$old_tag"
    else
        green_tag="$old_tag"
    fi
    compose up --detach --no-deps "$service"
    wait_for_container_ready "$service"
    set_weights 50 50
    return 1
}

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

deploy_api_slot blue
deploy_api_slot green

if [[ -n "$requested_tag" && "$job_tag" != "$requested_tag" ]]; then
    API_BLUE_IMAGE_TAG="$blue_tag" API_GREEN_IMAGE_TAG="$green_tag" \
        JOB_IMAGE_TAG="$requested_tag" APP_IMAGE_TAG="$app_tag" \
        docker compose --project-directory "$deployment_root" --file "$compose_file" \
        pull backend-job-dispatch backend-job-cleanup
    job_tag="$requested_tag"
    compose up --detach --no-deps backend-job-dispatch
    compose up --detach --no-deps backend-job-cleanup
    write_tag "$job_tag_file" "$requested_tag"
fi

docker logout "$registry" >/dev/null 2>&1
logged_in=false

curl --fail --silent --show-error http://127.0.0.1:8080/ready >/dev/null
compose ps
