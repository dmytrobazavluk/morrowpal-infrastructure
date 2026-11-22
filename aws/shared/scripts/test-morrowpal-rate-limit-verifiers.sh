#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly general_verifier="$script_directory/verify-rate-limit.sh"
readonly account_verifier="$script_directory/verify-account-creation-rate-limit.sh"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then
        fail "Command unexpectedly succeeded: $*"
    fi
}

assert_dry_run() {
    local expected="$1"
    shift
    local output

    output="$("$@")" || fail "Dry run failed: $*"
    [[ "$output" == *"$expected"* ]] \
        || fail "Dry run did not target the expected endpoint: $expected"
}

main() {
    bash -n "$general_verifier" "$account_verifier"

    assert_fails "$general_verifier"
    assert_fails "$account_verifier"
    assert_fails "$general_verifier" qa https://api.staging.morrowpal.com/ready --dry-run
    assert_fails "$account_verifier" qa https://api.staging.morrowpal.com/accounts --dry-run

    assert_fails \
        "$general_verifier" staging https://api.morrowpal.com/ready --dry-run
    assert_fails \
        "$account_verifier" staging https://api.morrowpal.com/accounts --dry-run
    assert_fails \
        "$general_verifier" staging https://api.staging.morrowpal.com/ready \
        --confirm-production --dry-run

    assert_dry_run \
        'https://api.staging.morrowpal.com/ready' \
        "$general_verifier" staging https://api.staging.morrowpal.com/ready --dry-run
    assert_dry_run \
        'https://api.staging.morrowpal.com/accounts' \
        "$account_verifier" staging https://api.staging.morrowpal.com/accounts --dry-run

    assert_fails \
        "$general_verifier" prod https://api.morrowpal.com/ready --dry-run
    assert_fails \
        "$account_verifier" prod https://api.morrowpal.com/accounts --dry-run
    assert_dry_run \
        'https://api.morrowpal.com/ready' \
        "$general_verifier" prod https://api.morrowpal.com/ready \
        --confirm-production --dry-run
    assert_dry_run \
        'https://api.morrowpal.com/accounts' \
        "$account_verifier" prod https://api.morrowpal.com/accounts \
        --confirm-production --dry-run

    printf 'MorrowPal rate-limit verifier validation passed.\n'
}

main "$@"
