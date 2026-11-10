#!/usr/bin/env bash

set -Eeuo pipefail

# Call directly, not through command substitution: the descriptor holds the
# component lock until the publisher exits, including on failure.
morrowpal_reserve_build_number() {
    local component="$1"
    local repository_directory="$2"
    local counter_file="$repository_directory/build-numbers/$component"
    local previous

    case "$component" in backend|app|website) ;; *) return 1 ;; esac
    command -v flock >/dev/null 2>&1 || {
        printf 'Required command not found: flock\n' >&2
        return 1
    }
    [[ -f "$counter_file" ]] || {
        printf 'Build counter not found: %s\n' "$counter_file" >&2
        return 1
    }
    exec {MORROWPAL_BUILD_LOCK_FD}<>"$counter_file"
    flock --nonblock "$MORROWPAL_BUILD_LOCK_FD" || {
        printf 'Another %s publishing build is running in this checkout.\n' "$component" >&2
        return 1
    }
    previous="$(cat "$counter_file")"
    [[ "$previous" =~ ^(0|[1-9][0-9]{0,8})$ ]] || {
        printf 'Invalid build counter: %s\n' "$counter_file" >&2
        return 1
    }
    MORROWPAL_BUILD_NUMBER=$((previous + 1))
    printf '%s\n' "$MORROWPAL_BUILD_NUMBER" >"$counter_file"
    printf 'Reserved %s build %s. Commit %s even if the build fails.\n' \
        "$component" "$MORROWPAL_BUILD_NUMBER" "$counter_file" >&2
}

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
                --args "src=$repository_directory/shared/runtime/compose.env.j2 dest=$environment_file mode=0600" \
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
