#!/usr/bin/env bash

set -Eeuo pipefail

readonly request_count=160
readonly batch_size=20
readonly batch_delay_seconds=1

usage() {
    cat <<'EOF'
Usage: verify-rate-limit.sh ENVIRONMENT TARGET_URL [--confirm-production] [--dry-run]

Send 160 requests in controlled batches to the selected API readiness
endpoint and verify that Envoy returns both HTTP 200 and Envoy-generated HTTP
429 responses. The check relies on the readiness endpoint normally returning
HTTP 200; it does not require a rate-limit response header.

ENVIRONMENT must be prod or staging. TARGET_URL must be that environment's
exact API readiness URL. Production requires --confirm-production.

The test consumes one client-IP rate-limit bucket. Wait at least 60 seconds
before retrying from the same public IP.
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
        [[ "$target_url" == "https://api.morrowpal.com/ready" ]] \
            || fail "Production target must be https://api.morrowpal.com/ready"
        [[ "$confirm_production" == true ]] \
            || fail "Production verification requires --confirm-production"
        ;;
    staging)
        [[ "$target_url" == "https://api.staging.morrowpal.com/ready" ]] \
            || fail "Staging target must be https://api.staging.morrowpal.com/ready"
        [[ "$confirm_production" == false ]] \
            || fail "--confirm-production cannot be used with staging"
        ;;
    *)
        fail "ENVIRONMENT must be prod or staging"
        ;;
esac

if [[ "$dry_run" == true ]]; then
    printf 'Dry run: would test the %s per-client-IP rate limit at %s with %d requests.\n' \
        "$environment" "$target_url" "$request_count"
    exit 0
fi

command -v curl >/dev/null 2>&1 || fail "Required command not found: curl"

results_dir="$(mktemp -d)"
trap 'rm -rf -- "$results_dir"' EXIT

allowed=0
rate_limited=0
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
        "$target_url")"; then
        printf '%s\n' "$status" >"$results_dir/$request.status"
    else
        printf 'transport-error\n' >"$results_dir/$request.status"
    fi
}

printf 'Testing %s with %d requests in batches of %d per second.\n' \
    "$target_url" "$request_count" "$batch_size"

for ((batch_start = 1; batch_start <= request_count; batch_start += batch_size)); do
    batch_end=$((batch_start + batch_size - 1))
    ((batch_end > request_count)) && batch_end=$request_count

    for ((request = batch_start; request <= batch_end; request++)); do
        perform_request "$request" &
    done
    wait

    if ((batch_end < request_count)); then
        sleep "$batch_delay_seconds"
    fi
done

for ((request = 1; request <= request_count; request++)); do
    status="$(<"$results_dir/$request.status")"
    if [[ "$status" == "transport-error" ]]; then
        ((transport_errors += 1))
    elif [[ "$status" == "200" ]]; then
        ((allowed += 1))
    elif [[ "$status" == "429" ]]; then
        ((rate_limited += 1))
    else
        ((unexpected += 1))
        printf 'Request %d returned unexpected HTTP status %s.\n' \
            "$request" "$status" >&2
    fi
done

printf 'Results: allowed=%d, envoy_rate_limited=%d, unexpected=%d, transport_errors=%d\n' \
    "$allowed" "$rate_limited" "$unexpected" "$transport_errors"

((transport_errors == 0)) || fail "One or more requests failed before receiving an HTTP response"
((unexpected == 0)) || fail "One or more responses were neither HTTP 200 nor HTTP 429"
((allowed > 0)) || fail "No request was allowed; wait at least 60 seconds and retry"
((rate_limited > 0)) || fail "Envoy did not rate-limit any request"

printf 'PASS: the %s per-client-IP rate limit is enforced by Envoy.\n' "$environment"
