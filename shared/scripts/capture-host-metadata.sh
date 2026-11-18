#!/usr/bin/env bash
set -Eeuo pipefail
mountpoint -q /var/lib/morrowpal
instance_id="$(cat /sys/devices/virtual/dmi/id/board_asset_tag)"
[[ "$instance_id" =~ ^i-([0-9a-f]{8}|[0-9a-f]{17})$ ]]
mapfile -t containers < <(docker ps -q --filter label=com.docker.compose.project=morrowpal)
((${#containers[@]} == 8)) || { printf 'Expected eight running project containers\n' >&2; exit 1; }
container_json="$(docker inspect --format '{"name":{{json .Name}},"image":{{json .Config.Image}},"imageId":{{json .Image}},"state":{{json .State.Status}}}' "${containers[@]}" | jq -s .)"
mapfile -t images < <(jq -r '.[].imageId' <<<"$container_json" | sort -u)
repo_digests="$(for image in "${images[@]}"; do docker image inspect --format '{{json .RepoDigests}}' "$image" | jq --arg id "$image" '{imageId:$id,repoDigests:.}'; done | jq -s .)"
jq -n --arg instanceId "$instance_id" --arg kernel "$(uname -r)" --arg os "$(rpm -q system-release)" --arg docker "$(docker --version)" \
    --arg compose "$(docker compose version)" --arg uuid "$(findmnt -n -o UUID --target /var/lib/morrowpal)" \
    --arg filesystem "$(findmnt -n -o FSTYPE --target /var/lib/morrowpal)" \
    --argjson containers "$container_json" --argjson images "$repo_digests" \
    '{instanceId:$instanceId,kernel:$kernel,os:$os,docker:$docker,compose:$compose,filesystemUuid:$uuid,filesystem:$filesystem,containers:$containers,images:$images}'
