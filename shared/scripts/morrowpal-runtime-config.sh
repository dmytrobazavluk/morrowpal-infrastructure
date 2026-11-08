#!/usr/bin/env bash

set -Eeuo pipefail

morrowpal_secret_reference() {
    local secret_id="$1"
    local json_key="${2:-}"

    [[ -n "$secret_id" ]] || {
        printf 'Secret identifier is required.\n' >&2
        return 1
    }

    if [[ -n "$json_key" ]]; then
        printf '{{resolve:secretsmanager:%s:SecretString:%s}}' "$secret_id" "$json_key"
    else
        printf '{{resolve:secretsmanager:%s}}' "$secret_id"
    fi
}

morrowpal_require_environment_values() {
    local variable_name

    for variable_name in "$@"; do
        [[ -n "${!variable_name:-}" ]] || {
            printf 'Required environment value is missing: %s\n' "$variable_name" >&2
            return 1
        }
    done
}
