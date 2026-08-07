#!/usr/bin/env bash

set -Eeuo pipefail

readonly tls_group_gid=1901
readonly letsencrypt_root=/etc/letsencrypt

lineage="${RENEWED_LINEAGE:-$letsencrypt_root/live/morrowpal.com}"
case "$lineage" in
    "$letsencrypt_root"/live/*)
        ;;
    *)
        printf 'Refusing unexpected certificate lineage: %s\n' "$lineage" >&2
        exit 1
        ;;
esac

certificate_name="${lineage##*/}"
archive="$letsencrypt_root/archive/$certificate_name"

[[ -d "$lineage" && -d "$archive" ]] || {
    printf 'Certificate lineage is incomplete: %s\n' "$certificate_name" >&2
    exit 1
}

chmod 0755 "$letsencrypt_root" "$letsencrypt_root/live" "$letsencrypt_root/archive"
chown "root:$tls_group_gid" "$lineage" "$archive"
chmod 0750 "$lineage" "$archive"

shopt -s nullglob
private_keys=("$archive"/privkey*.pem)
(( ${#private_keys[@]} > 0 )) || {
    printf 'No private keys found for certificate lineage: %s\n' "$certificate_name" >&2
    exit 1
}

chown "root:$tls_group_gid" "${private_keys[@]}"
chmod 0640 "${private_keys[@]}"

# Certbot updates its live symlinks before running deploy hooks. Replacing the
# two watched links after fixing permissions gives Envoy an atomic move event at
# the point when both files are readable.
for link_name in fullchain.pem privkey.pem; do
    link_path="$lineage/$link_name"
    [[ -L "$link_path" ]] || {
        printf 'Expected certificate symlink is missing: %s\n' "$link_path" >&2
        exit 1
    }
    link_target="$(readlink -- "$link_path")"
    replacement_link="$lineage/.$link_name.morrowpal-new"
    ln -sfn -- "$link_target" "$replacement_link"
    mv -Tf -- "$replacement_link" "$link_path"
done
