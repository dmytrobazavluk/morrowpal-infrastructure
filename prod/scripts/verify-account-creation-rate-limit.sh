#!/usr/bin/env bash

set -Eeuo pipefail

readonly request_count=30

usage() {
    cat <<'EOF'
Usage: verify-account-creation-rate-limit.sh ENVIRONMENT TARGET_URL [--confirm-production] [--dry-run]

Send 30 deliberately invalid account-creation requests to the selected API
and verify that Envoy allows some requests to reach backend validation before
returning Envoy-generated HTTP 429 responses.

ENVIRONMENT must be prod or staging. TARGET_URL must be that environment's
exact account-creation URL. Production requires --confirm-production.

The '{}' request body fails backend validation and does not create an account.
The test consumes the caller's 25-token account-creation bucket and part of the
general API bucket. Wait at least 60 seconds before retrying from the same
public IP.

This test verifies the selected environment's per-client-IP account-creation bucket. A
single runner cannot independently exhaust the 50-token global bucket without
first exhausting its own 25-token bucket.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if (($# < 2)); then
    usage >&2
    exit 2
fi

readonly environment="$1"
readonly target_url="$2"
shift 2
confirm_production=false
dry_run=false
for option in "$@"; do
    case "$option" in
        --confirm-production)
            confirm_production=true
            ;;
        --dry-run)
            dry_run=true
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$environment" in
    prod)
        [[ "$target_url" == "https://api.morrowpal.com/accounts" ]] \
            || fail "Production target must be https://api.morrowpal.com/accounts"
        [[ "$confirm_production" == true ]] \
            || fail "Production verification requires --confirm-production"
        ;;
    staging)
        [[ "$target_url" == "https://api.staging.morrowpal.com/accounts" ]] \
            || fail "Staging target must be https://api.staging.morrowpal.com/accounts"
        [[ "$confirm_production" == false ]] \
            || fail "--confirm-production cannot be used with staging"
        ;;
    *)
        fail "ENVIRONMENT must be prod or staging"
        ;;
esac

if [[ "$dry_run" == true ]]; then
    printf 'Dry run: would test the %s account-creation rate limit at %s with %d invalid requests.\n' \
        "$environment" "$target_url" "$request_count"
    exit 0
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

printf 'PASS: the %s account-creation per-client-IP limit is enforced by Envoy.\n' \
    "$environment"
