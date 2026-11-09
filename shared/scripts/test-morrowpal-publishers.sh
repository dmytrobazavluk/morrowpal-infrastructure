#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly backend_publisher="$script_directory/publish-images.sh"
readonly app_publisher="$script_directory/publish-app-image.sh"
readonly website_publisher="$script_directory/publish-website-image.sh"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

install_mock_aws() {
    local mock_directory="$1"

    install -d -m 0700 "$mock_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'printf "aws:%s\\n" "$*" >>"$MORROWPAL_MOCK_LOG"' \
        'if [[ "${1:-}" == sts && "${2:-}" == get-caller-identity ]]; then' \
        '  printf "%s\\n" "$MORROWPAL_MOCK_ACCOUNT_ID"' \
        'fi' >"$mock_directory/aws"
    chmod 0700 "$mock_directory/aws"
}

assert_output_contains() {
    local output_file="$1"
    local expected="$2"

    grep -Fq -- "$expected" "$output_file" || fail "Missing dry-run output: $expected"
}

run_dry_runs() {
    local environment="$1"
    local expected_prefix="$2"
    local expected_api_url="$3"
    local mock_directory="$4"
    local mock_log="$5"
    local output_file="$6"

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_MOCK_ACCOUNT_ID=384078510608 \
    MORROWPAL_PUBLISH_DRY_RUN=true \
        "$backend_publisher" "$environment" 2 >"$output_file"
    assert_output_contains "$output_file" "/$expected_prefix/backend-api"
    assert_output_contains "$output_file" "/$expected_prefix/backend-job"

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_MOCK_ACCOUNT_ID=384078510608 \
    MORROWPAL_PUBLISH_DRY_RUN=true \
        "$app_publisher" "$environment" 1.1.0 2 >"$output_file"
    assert_output_contains "$output_file" "/$expected_prefix/app"
    assert_output_contains "$output_file" "environment-independent app image"

    PATH="$mock_directory:$PATH" \
    MORROWPAL_MOCK_LOG="$mock_log" \
    MORROWPAL_MOCK_ACCOUNT_ID=384078510608 \
    MORROWPAL_PUBLISH_DRY_RUN=true \
        "$website_publisher" "$environment" 2 >"$output_file"
    assert_output_contains "$output_file" "/$expected_prefix/website"
}

main() {
    local cleanup_command
    local mismatch_log
    local mock_directory
    local mock_log
    local output_file
    local test_directory

    bash -n \
        "$backend_publisher" \
        "$app_publisher" \
        "$website_publisher" \
        "$script_directory/morrowpal-publish-config.sh"

    test_directory="$(mktemp -d)"
    printf -v cleanup_command 'rm -rf -- %q' "$test_directory"
    trap "$cleanup_command" EXIT
    mock_directory="$test_directory/bin"
    mock_log="$test_directory/aws.log"
    mismatch_log="$test_directory/mismatch.log"
    output_file="$test_directory/output"
    install_mock_aws "$mock_directory"

    run_dry_runs \
        prod \
        morrowpal/prod \
        https://api.morrowpal.com \
        "$mock_directory" \
        "$mock_log" \
        "$output_file"
    run_dry_runs \
        staging \
        morrowpal/staging \
        https://api.staging.morrowpal.com \
        "$mock_directory" \
        "$mock_log" \
        "$output_file"

    if PATH="$mock_directory:$PATH" \
        MORROWPAL_MOCK_LOG="$mismatch_log" \
        MORROWPAL_MOCK_ACCOUNT_ID=000000000000 \
        MORROWPAL_PUBLISH_DRY_RUN=true \
            "$backend_publisher" staging 2 >/dev/null 2>&1; then
        fail "Publisher accepted an AWS account mismatch"
    fi
    if PATH="$mock_directory:$PATH" \
        MORROWPAL_MOCK_LOG="$mismatch_log" \
        MORROWPAL_MOCK_ACCOUNT_ID=000000000000 \
        MORROWPAL_PUBLISH_DRY_RUN=true \
            "$app_publisher" staging 1.1.0 2 >/dev/null 2>&1; then
        fail "App publisher accepted an AWS account mismatch"
    fi
    if PATH="$mock_directory:$PATH" \
        MORROWPAL_MOCK_LOG="$mismatch_log" \
        MORROWPAL_MOCK_ACCOUNT_ID=000000000000 \
        MORROWPAL_PUBLISH_DRY_RUN=true \
            "$website_publisher" staging 2 >/dev/null 2>&1; then
        fail "Website publisher accepted an AWS account mismatch"
    fi
    grep -Fq 'aws:sts get-caller-identity' "$mismatch_log" \
        || fail "Account mismatch test did not check the active AWS identity"
    if grep -Eq 'ecr|get-login-password' "$mismatch_log"; then
        fail "Account mismatch reached an ECR operation"
    fi

    if "$backend_publisher" 2 >/dev/null 2>&1; then
        fail "Backend publisher accepted a missing environment"
    fi
    if PATH="$mock_directory:$PATH" \
        MORROWPAL_MOCK_LOG="$mock_log" \
        MORROWPAL_MOCK_ACCOUNT_ID=384078510608 \
        MORROWPAL_PUBLISH_DRY_RUN=true \
            "$backend_publisher" qa 2 >/dev/null 2>&1; then
        fail "Backend publisher accepted an unknown environment"
    fi

    printf 'MorrowPal image publisher validation passed.\n'
}

main "$@"
