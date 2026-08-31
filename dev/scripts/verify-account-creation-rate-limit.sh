#!/usr/bin/env bash

set -Eeuo pipefail

readonly envoy_image="envoyproxy/envoy:v1.39.0@sha256:d59f7f5fa10cff6d5892b6c5e7df5c9297ddfb2c3683e33fbfb82da24de4fa66"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly envoy_config_dir="$script_dir/../envoy"
readonly resource_suffix="$$"
readonly network_name="morrowpal-envoy-rate-limit-test-$resource_suffix"
readonly envoy_container="morrowpal-envoy-rate-limit-envoy-$resource_suffix"
readonly client_one="morrowpal-envoy-rate-limit-client-one-$resource_suffix"
readonly client_two="morrowpal-envoy-rate-limit-client-two-$resource_suffix"
readonly client_three="morrowpal-envoy-rate-limit-client-three-$resource_suffix"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    docker stop "$client_one" "$client_two" "$client_three" "$envoy_container" \
        >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
}

request_status() {
    local client_container="$1"
    local method="$2"
    local path="$3"

    docker exec \
        -e REQUEST_METHOD="$method" \
        -e REQUEST_PATH="$path" \
        -e ENVOY_HOST="$envoy_container" \
        "$client_container" \
        bash -c '
            exec 3<>"/dev/tcp/$ENVOY_HOST/8080"
            printf "%s %s HTTP/1.1\r\nHost: test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" \
                "$REQUEST_METHOD" "$REQUEST_PATH" >&3
            IFS=" " read -r _ status _ <&3
            printf "%s\n" "$status"
        '
}

expect_status() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == "$expected" ]] || \
        fail "$description returned HTTP $actual; expected HTTP $expected"
}

command -v docker >/dev/null 2>&1 || fail "Required command not found: docker"
[[ -f "$envoy_config_dir/envoy.yaml" ]] || fail "Development Envoy configuration was not found"

trap cleanup EXIT

printf 'Validating the development Envoy configuration.\n'
docker run --rm \
    --volume "$envoy_config_dir:/config:ro" \
    "$envoy_image" \
    --mode validate \
    --config-path /config/envoy.yaml \
    >/dev/null

docker network create "$network_name" >/dev/null

docker run --rm --detach \
    --name "$envoy_container" \
    --network "$network_name" \
    --volume "$envoy_config_dir:/etc/envoy:ro" \
    "$envoy_image" \
    >/dev/null

for client_container in "$client_one" "$client_two" "$client_three"; do
    docker run --rm --detach \
        --name "$client_container" \
        --network "$network_name" \
        --entrypoint bash \
        "$envoy_image" \
        -c 'sleep infinity' \
        >/dev/null
done

printf 'Waiting for the isolated Envoy listener.\n'
listener_ready=false
for ((attempt = 1; attempt <= 30; attempt++)); do
    if status="$(request_status "$client_three" GET /ready 2>/dev/null)"; then
        listener_ready=true
        break
    fi
    sleep 0.1
done
[[ "$listener_ready" == "true" ]] || fail "Envoy did not become ready"
expect_status "$status" 503 "Unrouted readiness probe"

printf 'Verifying the per-IP burst of 25 account-creation requests.\n'
for ((request = 1; request <= 25; request++)); do
    status="$(request_status "$client_one" POST /accounts)"
    expect_status "$status" 503 "Per-IP request $request"
done

status="$(request_status "$client_one" POST /accounts)"
expect_status "$status" 429 "Per-IP request 26"

printf 'Verifying the global burst of 50 across multiple client IPs.\n'
for ((request = 26; request <= 50; request++)); do
    status="$(request_status "$client_two" POST /accounts)"
    expect_status "$status" 503 "Global request $request"
done

status="$(request_status "$client_three" POST '/accounts?test=global-limit')"
expect_status "$status" 429 "Global request 51"

printf 'Verifying that the registration bucket does not limit other requests.\n'
status="$(request_status "$client_three" GET /accounts)"
expect_status "$status" 503 "Non-registration request"

printf 'PASS: Envoy enforces account creation at 25 burst/1 per minute per IP and 50 burst/2 per minute globally.\n'
