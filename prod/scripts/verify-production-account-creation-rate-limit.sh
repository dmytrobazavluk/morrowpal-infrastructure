#!/usr/bin/env bash

set -Eeuo pipefail

readonly target_url="https://api.morrowpal.com/accounts"
readonly request_count=30

usage() {
    cat <<'EOF'
Usage: verify-production-account-creation-rate-limit.sh --confirm-production

Send 30 deliberately invalid account-creation requests to the production API
and verify that Envoy allows some requests to reach backend validation before
returning Envoy-generated HTTP 429 responses.

The '{}' request body fails backend validation and does not create an account.
The test consumes the caller's 25-token account-creation bucket and part of the
general API bucket. Wait at least 60 seconds before retrying from the same
public IP.

This test verifies the production per-client-IP account-creation bucket. A
single runner cannot independently exhaust the 50-token global bucket without
first exhausting its own 25-token bucket.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if (($# != 1)) || [[ "$1" != "--confirm-production" ]]; then
    usage >&2
    exit 2
fi

command -v curl >/dev/null 2>&1 || fail "Required command not found: curl"

results_dir="$(mktemp -d)"
trap 'rm -rf -- "$results_dir"' EXIT

backend_rejected=0
envoy_rate_limited=0
unexpected=0
transport_errors=0

perform_request() {
    local request="$1"
    local status=""

    if status="$(curl \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout 5 \
        --max-time 10 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{}' \
        "$target_url")"; then
        printf '%s\n' "$status" >"$results_dir/$request.status"
    else
        printf 'transport-error\n' >"$results_dir/$request.status"
    fi
}

printf 'Testing %s with %d invalid registration requests.\n' \
    "$target_url" "$request_count"

for ((request = 1; request <= request_count; request++)); do
    perform_request "$request" &
done
wait

for ((request = 1; request <= request_count; request++)); do
    status="$(<"$results_dir/$request.status")"
    if [[ "$status" == "transport-error" ]]; then
        ((transport_errors += 1))
    elif [[ "$status" == "400" ]]; then
        ((backend_rejected += 1))
    elif [[ "$status" == "429" ]]; then
        ((envoy_rate_limited += 1))
    else
        ((unexpected += 1))
        printf 'Request %d returned unexpected HTTP status %s.\n' \
            "$request" "$status" >&2
    fi
done

printf 'Results: backend_rejected=%d, envoy_rate_limited=%d, unexpected=%d, transport_errors=%d\n' \
    "$backend_rejected" "$envoy_rate_limited" "$unexpected" "$transport_errors"

((transport_errors == 0)) || fail "One or more requests failed before receiving an HTTP response"
((unexpected == 0)) || fail "One or more responses were not expected backend or Envoy responses"
((backend_rejected > 0)) || fail "No request reached backend validation; wait at least 60 seconds and retry"
((envoy_rate_limited > 0)) || fail "Envoy did not enforce the account-creation limit"

printf 'PASS: the production account-creation per-client-IP limit is enforced by Envoy.\n'
