#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly shared_directory="$(cd -- "$script_directory/.." && pwd)"
readonly repository_directory="$(cd -- "$shared_directory/.." && pwd)"
readonly prod_directory="$repository_directory/prod"
readonly sds_template="$repository_directory/shared/runtime/envoy/tls-certificate-sds.yaml.j2"
readonly hook_template="$repository_directory/shared/runtime/envoy/configure-tls-permissions.sh.j2"
readonly sds_baseline="$prod_directory/baselines/tls-certificate-sds-production.sha256"
readonly hook_baseline="$prod_directory/baselines/tls-permissions-production.sha256"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

render_template() {
    local environment="$1"
    local source="$2"
    local destination="$3"
    local mode="$4"

    ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
    ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
        ansible localhost \
            -i localhost, \
            --connection local \
            --module-name ansible.builtin.template \
            --args "src=$source dest=$destination mode=$mode" \
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
    digest_output="$(sha256sum "$rendered_file")"
    actual_digest="${digest_output%% *}"
    [[ "$actual_digest" == "$expected_digest" ]] \
        || fail "Rendered file differs from production baseline: $rendered_file"
}

main() {
    local cleanup_command
    local environment
    local prod_hook
    local prod_sds
    local staging_hook
    local staging_sds

    command -v ansible >/dev/null 2>&1 || fail "Required command not found: ansible"
    command -v ansible-playbook >/dev/null 2>&1 || fail "Required command not found: ansible-playbook"

    prod_sds="$(mktemp)"
    prod_hook="$(mktemp)"
    staging_sds="$(mktemp)"
    staging_hook="$(mktemp)"
    printf -v cleanup_command \
        'rm -f -- %q %q %q %q' \
        "$prod_sds" \
        "$prod_hook" \
        "$staging_sds" \
        "$staging_hook"
    trap "$cleanup_command" EXIT

    render_template prod "$sds_template" "$prod_sds" 0600
    render_template prod "$hook_template" "$prod_hook" 0700
    render_template staging "$sds_template" "$staging_sds" 0600
    render_template staging "$hook_template" "$staging_hook" 0700

    assert_digest "$prod_sds" "$sds_baseline"
    assert_digest "$prod_hook" "$hook_baseline"
    bash -n "$prod_hook"
    bash -n "$staging_hook"

    grep -Fq '/etc/letsencrypt/live/staging.morrowpal.com/fullchain.pem' "$staging_sds" \
        || fail "Staging SDS configuration has the wrong certificate chain path"
    grep -Fq '/etc/letsencrypt/live/staging.morrowpal.com/privkey.pem' "$staging_sds" \
        || fail "Staging SDS configuration has the wrong private-key path"
    grep -Fq 'lineage="${RENEWED_LINEAGE:-$letsencrypt_root/live/staging.morrowpal.com}"' "$staging_hook" \
        || fail "Staging permission hook has the wrong default lineage"
    if grep -Fq '/live/morrowpal.com' "$staging_sds" "$staging_hook"; then
        fail "Staging TLS rendering contains the production certificate lineage"
    fi

    if grep -Eq '3\.12\.65\.199|(^|[^.])morrowpal\.com' "$shared_directory/playbooks/prepare-tls.yml"; then
        fail "TLS preparation playbook contains a production-only IP address or domain"
    fi
    grep -Eq '^  hosts: morrowpal_hosts$' "$shared_directory/playbooks/prepare-tls.yml" \
        || fail "TLS preparation playbook does not target the neutral host group"

    for environment in prod staging; do
        ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
            ansible-playbook \
                -i "$repository_directory/environments/$environment/inventory.ini" \
                -e "@$repository_directory/environments/$environment/vars.yml" \
                --syntax-check \
                "$shared_directory/playbooks/prepare-tls.yml" >/dev/null
    done

    printf 'MorrowPal TLS template validation passed.\n'
}

main "$@"
