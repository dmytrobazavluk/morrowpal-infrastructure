#!/usr/bin/env bash

set -Eeuo pipefail

readonly secrets_directory=/run/morrowpal/secrets

: "${MYSQL_APP_PASSWORD:?MYSQL_APP_PASSWORD is required}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
: "${JWT_SIGNING_SECRET:?JWT_SIGNING_SECRET is required}"

install -d -o root -g root -m 0700 "$secrets_directory"

write_secret() {
    local destination="$1"
    local value="$2"
    local temporary_file

    temporary_file="$(mktemp "$secrets_directory/.secret.XXXXXX")"
    printf '%s' "$value" >"$temporary_file"
    chown root:root "$temporary_file"
    chmod 0444 "$temporary_file"
    mv -f "$temporary_file" "$destination"
}

write_secret "$secrets_directory/mysql-app-password" "$MYSQL_APP_PASSWORD"
write_secret "$secrets_directory/mysql-root-password" "$MYSQL_ROOT_PASSWORD"
write_secret "$secrets_directory/jwt-signing-secret" "$JWT_SIGNING_SECRET"
