#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly shared_directory="$(cd -- "$script_directory/.." && pwd)"
readonly repository_directory="$(cd -- "$shared_directory/.." && pwd)"
readonly prod_directory="$repository_directory/prod"
readonly app_template="$shared_directory/runtime/app/nginx.conf.j2"
readonly website_template="$shared_directory/runtime/website/nginx.conf.j2"
readonly app_baseline="$prod_directory/baselines/app-nginx-production.sha256"
readonly website_baseline="$prod_directory/baselines/website-nginx-production.sha256"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

render_nginx() {
    local environment="$1"
    local template="$2"
    local destination="$3"

    ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
    ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
        ansible localhost \
            -i localhost, \
            --connection local \
            --module-name ansible.builtin.template \
            --args "src=$template dest=$destination mode=0600" \
            --extra-vars "@$repository_directory/environments/$environment/vars.yml" >/dev/null
}

assert_digest() {
    local rendered_file="$1"
    local baseline_file="$2"
    local actual_digest
    local expected_digest
    local digest_output

    IFS= read -r expected_digest <"$baseline_file" \
        || fail "Could not read baseline: $baseline_file"
    if [[ "$baseline_file" == "$app_baseline" ]]; then
        # Keep the captured production baseline. Exclude only the two new
        # runtime configuration locations from this legacy comparison.
        digest_output="$(sed '/^    location = \/runtime-config.js {/,/^    location = \/notifications\/disable {/ { /^    location = \/notifications\/disable {/!d; }' "$rendered_file" | sha256sum)"
    else
        digest_output="$(sha256sum "$rendered_file")"
    fi
    actual_digest="${digest_output%% *}"
    [[ "$actual_digest" == "$expected_digest" ]] \
        || fail "Rendered Nginx configuration differs from production baseline"
}

main() {
    local cleanup_command
    local normalized_staging_app
    local normalized_staging_website
    local prod_app
    local prod_website
    local staging_app
    local staging_website

    command -v ansible >/dev/null 2>&1 || fail "Required command not found: ansible"

    prod_app="$(mktemp)"
    prod_website="$(mktemp)"
    staging_app="$(mktemp)"
    staging_website="$(mktemp)"
    normalized_staging_app="$(mktemp)"
    normalized_staging_website="$(mktemp)"
    printf -v cleanup_command \
        'rm -f -- %q %q %q %q %q %q' \
        "$prod_app" "$prod_website" \
        "$staging_app" "$staging_website" \
        "$normalized_staging_app" "$normalized_staging_website"
    trap "$cleanup_command" EXIT

    render_nginx prod "$app_template" "$prod_app"
    render_nginx prod "$website_template" "$prod_website"
    render_nginx staging "$app_template" "$staging_app"
    render_nginx staging "$website_template" "$staging_website"

    assert_digest "$prod_app" "$app_baseline"
    assert_digest "$prod_website" "$website_baseline"

    for rendered in "$prod_app" "$staging_app"; do
        grep -Fq 'alias /etc/morrowpal/runtime-config.js;' "$rendered" \
            || fail "App does not serve deployment runtime configuration"
        grep -A4 -F 'location = /runtime-config.js {' "$rendered" \
            | grep -Fq 'Cache-Control "no-store"' \
            || fail "Runtime configuration must not be cached"
        grep -A3 -F 'location = /firebase-messaging-sw.js {' "$rendered" \
            | grep -Fq 'try_files $uri =404;' \
            || fail "Missing notification workers must not fall back to app HTML"
    done

    grep -Fq 'https://staging.morrowpal.com/notifications/disable/' "$staging_app" \
        || fail "Staging app redirect is incorrect"
    grep -Fq 'connect-src https://api.staging.morrowpal.com;' "$staging_website" \
        || fail "Staging website CSP API origin is incorrect"
    grep -Fq 'https://staging.morrowpal.com/privacy/' "$staging_website" \
        || fail "Staging website privacy redirect is incorrect"
    grep -Fq 'https://staging.morrowpal.com/child-safety/' "$staging_website" \
        || fail "Staging website child-safety redirect is incorrect"

    sed 's|https://staging.morrowpal.com|https://morrowpal.com|g' \
        "$staging_app" >"$normalized_staging_app"
    sed \
        -e 's|https://api.staging.morrowpal.com|https://api.morrowpal.com|g' \
        -e 's|https://staging.morrowpal.com|https://morrowpal.com|g' \
        "$staging_website" >"$normalized_staging_website"
    cmp --silent "$prod_app" "$normalized_staging_app" \
        || fail "App Nginx configurations differ outside the website URL"
    cmp --silent "$prod_website" "$normalized_staging_website" \
        || fail "Website Nginx configurations differ outside environment URLs"

    if grep -Fq '{{' "$prod_app" "$prod_website" "$staging_app" "$staging_website"; then
        fail "Rendered Nginx configuration contains an unresolved expression"
    fi

    if grep -Eq 'MORROWPAL_(WEBSITE|API)_URL|morrowpal\.com' \
            "$shared_directory/runtime/app/Dockerfile" \
            "$shared_directory/runtime/website/Dockerfile"; then
        fail "Nginx image definition contains environment-specific configuration"
    fi
    if grep -Eq -- '--build-arg.*MORROWPAL_(WEBSITE|API)_URL' \
            "$script_directory/publish-app-image.sh" \
            "$script_directory/publish-website-image.sh"; then
        fail "Image publisher passes Nginx environment configuration at build time"
    fi
    grep -Fq '${MORROWPAL_DEPLOYMENT_ROOT:?MORROWPAL_DEPLOYMENT_ROOT is required}/app/nginx.conf:/etc/nginx/conf.d/default.conf:ro' \
        "$shared_directory/docker-compose.yml" \
        || fail "Compose does not mount the app Nginx configuration read-only"
    grep -Fq '${MORROWPAL_DEPLOYMENT_ROOT:?MORROWPAL_DEPLOYMENT_ROOT is required}/website/nginx.conf:/etc/nginx/conf.d/default.conf:ro' \
        "$shared_directory/docker-compose.yml" \
        || fail "Compose does not mount the website Nginx configuration read-only"
    grep -Fq 'src: ../runtime/app/nginx.conf.j2' "$shared_directory/playbooks/deploy.yml" \
        || fail "Deployment does not render the app Nginx configuration"
    grep -Fq 'src: ../runtime/website/nginx.conf.j2' "$shared_directory/playbooks/deploy.yml" \
        || fail "Deployment does not render the website Nginx configuration"
    grep -Fq "(['--recreate-app'] if morrowpal_app_recreation_required else [])" \
        "$shared_directory/playbooks/deploy.yml" \
        || fail "Deployment does not recreate the app after its Nginx configuration changes"
    grep -Fq "(['--recreate-website'] if morrowpal_website_recreation_required else [])" \
        "$shared_directory/playbooks/deploy.yml" \
        || fail "Deployment does not recreate the website after its Nginx configuration changes"

    printf 'MorrowPal Nginx template validation passed.\n'
}

main "$@"
