#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROD_VARS="$REPOSITORY_DIR/environments/prod/vars.yml"
readonly STAGING_VARS="$REPOSITORY_DIR/environments/staging/vars.yml"
readonly PROD_INVENTORY="$REPOSITORY_DIR/environments/prod/inventory.ini"
readonly STAGING_INVENTORY="$REPOSITORY_DIR/environments/staging/inventory.ini"
readonly ANSIBLE_CONFIG_FILE="$REPOSITORY_DIR/ansible.cfg"
readonly -a NEUTRAL_HOST_PLAYBOOKS=(
    "$REPOSITORY_DIR/shared/playbooks/install-docker.yml"
    "$REPOSITORY_DIR/shared/playbooks/install-docker-compose.yml"
    "$REPOSITORY_DIR/shared/playbooks/prepare-host.yml"
    "$REPOSITORY_DIR/shared/playbooks/prepare-mysql.yml"
    "$REPOSITORY_DIR/shared/playbooks/prepare-storage.yml"
    "$REPOSITORY_DIR/shared/playbooks/prepare-tls.yml"
    "$REPOSITORY_DIR/shared/playbooks/deploy.yml"
)

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_key() {
    local file="$1"
    local key="$2"

    grep -Eq "^${key}:" "$file" \
        || fail "Missing required key '$key' in ${file#$REPOSITORY_DIR/}"
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"

    if grep -En "$pattern" "$file"; then
        fail "$message"
    fi
}

validate_vars_file() {
    local file="$1"
    local -a required_keys=(
        morrowpal_environment
        morrowpal_aws_account_id
        morrowpal_aws_region
        morrowpal_availability_zone
        morrowpal_stack_prefix
        morrowpal_ecr_registry
        morrowpal_ecr_repository_prefix
        morrowpal_secrets_prefix
        morrowpal_system_alerts_topic_name
        morrowpal_system_alerts_topic_arn
        morrowpal_system_alerts_provider
        morrowpal_instance_name
        morrowpal_instance_type
        morrowpal_root_volume_size_gib
        morrowpal_mysql_volume_size_gib
        morrowpal_deployment_root
        morrowpal_mysql_data_mount
        morrowpal_public_ipv4
        morrowpal_domains
        morrowpal_public_urls
        morrowpal_cors_allowed_origin_patterns
        morrowpal_store_review_email
        morrowpal_tls_certificate_name
        morrowpal_tls_expected_ipv4
        morrowpal_ssh_host_alias
        morrowpal_ssh_user
        morrowpal_ssh_private_key_file
        morrowpal_ssh_known_hosts_file
        morrowpal_postmark_mode
        morrowpal_email_provider
        morrowpal_postmark_server_name
        morrowpal_postmark_message_stream
        morrowpal_email_otp_from_address
        morrowpal_email_notification_from_address
        morrowpal_email_dispatch_opt_out_url
        morrowpal_app_notifications_provider
        morrowpal_firebase_project_id
    )
    local key

    [[ -f "$file" ]] || fail "Environment variable file not found: $file"
    for key in "${required_keys[@]}"; do
        require_key "$file" "$key"
    done
}

main() {
    local inventory
    local playbook
    local vars_file

    command -v ansible >/dev/null 2>&1 \
        || fail 'Required command not found: ansible'
    command -v ansible-inventory >/dev/null 2>&1 \
        || fail 'Required command not found: ansible-inventory'

    validate_vars_file "$PROD_VARS"
    validate_vars_file "$STAGING_VARS"

    grep -qx 'morrowpal_environment: prod' "$PROD_VARS" \
        || fail 'Production variable file must select prod'
    grep -qx 'morrowpal_environment: staging' "$STAGING_VARS" \
        || fail 'Staging variable file must select staging'

    reject_pattern \
        "$PROD_VARS" \
        'morrowpal/staging|morrowpal-staging|\.staging\.morrowpal\.com' \
        'Production variable file contains a staging resource path'
    reject_pattern \
        "$STAGING_VARS" \
        'morrowpal/prod|morrowpal-prod|https://(api\.|app\.|www\.)?morrowpal\.com([/:]|$)|verification-code@morrowpal\.com|notifications@morrowpal\.com' \
        'Staging variable file contains a production resource path'

    grep -qx '\[morrowpal_hosts\]' "$PROD_INVENTORY" \
        || fail 'Production inventory must use the morrowpal_hosts group'
    grep -qx '\[morrowpal_hosts\]' "$STAGING_INVENTORY" \
        || fail 'Staging inventory must use the morrowpal_hosts group'

    if grep -Eq '^[[:space:]]*(inventory|private_key_file)[[:space:]]*=' "$ANSIBLE_CONFIG_FILE"; then
        fail 'Root ansible.cfg must not select an inventory or private key'
    fi

    ANSIBLE_CONFIG="$ANSIBLE_CONFIG_FILE" \
        ansible localhost -i localhost, -e "@$PROD_VARS" --list-hosts >/dev/null
    ANSIBLE_CONFIG="$ANSIBLE_CONFIG_FILE" \
        ansible localhost -i localhost, -e "@$STAGING_VARS" --list-hosts >/dev/null
    ANSIBLE_CONFIG="$ANSIBLE_CONFIG_FILE" \
        ansible-inventory -i "$PROD_INVENTORY" --list >/dev/null
    ANSIBLE_CONFIG="$ANSIBLE_CONFIG_FILE" \
        ansible-inventory -i "$STAGING_INVENTORY" --list >/dev/null

    for playbook in "${NEUTRAL_HOST_PLAYBOOKS[@]}"; do
        grep -Eq '^  hosts: morrowpal_hosts$' "$playbook" \
            || fail "Playbook does not target the neutral host group: ${playbook#$REPOSITORY_DIR/}"
        if grep -Eq '(^|[^[:alnum:]_])production([^[:alnum:]_]|$)' "$playbook"; then
            fail "Neutral playbook contains a production-only target: ${playbook#$REPOSITORY_DIR/}"
        fi
        if grep -Eq '/opt/morrowpal|/var/lib/morrowpal' "$playbook"; then
            fail "Neutral playbook contains a hardcoded environment path: ${playbook#$REPOSITORY_DIR/}"
        fi
    done

    for inventory in "$PROD_INVENTORY" "$STAGING_INVENTORY"; do
        if [[ "$inventory" == "$PROD_INVENTORY" ]]; then
            vars_file="$PROD_VARS"
        else
            vars_file="$STAGING_VARS"
        fi
        for playbook in "${NEUTRAL_HOST_PLAYBOOKS[@]}"; do
            ANSIBLE_CONFIG="$ANSIBLE_CONFIG_FILE" \
                ansible-playbook \
                    -i "$inventory" \
                    --syntax-check \
                    "$playbook" \
                    --extra-vars "@$vars_file" >/dev/null
        done
    done

    printf 'Environment overlay validation passed.\n'
}

main "$@"
