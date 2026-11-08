#!/usr/bin/env bash

set -Eeuo pipefail

morrowpal_load_publish_environment() {
    local selected_environment="$1"
    local repository_directory="$2"
    local environment_file
    local expected_registry

    case "$selected_environment" in
        prod|staging)
            ;;
        *)
            printf 'Environment must be prod or staging.\n' >&2
            return 1
            ;;
    esac

    command -v ansible >/dev/null 2>&1 || {
        printf 'Required command not found: ansible\n' >&2
        return 1
    }

    environment_file="$(mktemp)"
    if ! ANSIBLE_CONFIG="$repository_directory/ansible.cfg" \
        ANSIBLE_REMOTE_TEMP=/tmp/morrowpal-ansible-remote \
            ansible localhost \
                -i localhost, \
                --connection local \
                --module-name ansible.builtin.template \
                --args "src=$repository_directory/prod/templates/compose.env.j2 dest=$environment_file mode=0600" \
                --extra-vars "@$repository_directory/environments/$selected_environment/vars.yml" >/dev/null; then
        rm -f -- "$environment_file"
        return 1
    fi

    set -a
    # shellcheck source=/dev/null
    source "$environment_file"
    set +a
    rm -f -- "$environment_file"

    morrowpal_require_environment_values \
        MORROWPAL_AWS_ACCOUNT_ID \
        MORROWPAL_AWS_REGION \
        MORROWPAL_ECR_REGISTRY \
        MORROWPAL_ECR_REPOSITORY_PREFIX

    expected_registry="${MORROWPAL_AWS_ACCOUNT_ID}.dkr.ecr.${MORROWPAL_AWS_REGION}.amazonaws.com"
    [[ "$MORROWPAL_ECR_REGISTRY" == "$expected_registry" ]] || {
        printf 'Configured ECR registry does not match the selected account and Region.\n' >&2
        return 1
    }

    export MORROWPAL_PUBLISH_ENVIRONMENT="$selected_environment"
}
