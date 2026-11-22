#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository="$(cd -- "$directory/../.." && pwd)"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'Usage: verify-staging-snapshot-restore.sh RECORD.json original|candidate'
record_path="$(realpath -- "$1")" target="$2"
case "$target" in original|candidate) ;; *) fail 'Invalid target' ;; esac
exec 9>/tmp/morrowpal-staging-host-handoff.lock
flock --exclusive --nonblock 9 || fail 'Another staging operation is running'
umask 077
work="$(mktemp -d)"
clone=''
trap 'rc=$?; rm -rf -- "$work"; if ((rc)) && [[ -n "$clone" ]]; then printf "Restore check failed; inspect diagnostic volume %s before cleanup. Original storage was not deleted.\n" "$clone" >&2; fi' EXIT
cp "$record_path" "$work/record.json"
record="$work/record.json"
cd "$repository"
bash "$directory/validate-replacement-record.sh" staging "$record"
bash "$directory/check-replacement-hosts.sh" staging "$record"
bash "$directory/check-replacement-storage.sh" staging "$record" "$target"
bash "$directory/check-replacement-ip.sh" staging "$record" "$target"
region="$(jq -r .region "$record")" zone="$(jq -r .availabilityZone "$record")"
snapshot="$(jq -r .data.snapshotId "$record")" uuid="$(jq -r .data.filesystemUuid "$record")"
instance="$(jq -r --arg target "$target" '.[$target].instanceId' "$record")"
ip="$(jq -r .publicIp.address "$record")"
aws ec2 create-volume --snapshot-id "$snapshot" --availability-zone "$zone" --volume-type gp3 --encrypted \
    --tag-specifications 'ResourceType=volume,Tags=[{Key=Environment,Value=staging},{Key=Application,Value=morrowpal},{Key=Purpose,Value=restore-check}]' \
    --region "$region" --output json >"$work/created.json"
jq -e --slurpfile record "$record" '
    (.VolumeId | type == "string" and test("^vol-([0-9a-f]{8}|[0-9a-f]{17})$"))
    and .VolumeId != $record[0].data.volumeId and .VolumeId != $record[0].original.rootVolumeId and .VolumeId != $record[0].candidate.rootVolumeId
' "$work/created.json" >/dev/null || fail 'Diagnostic volume ID overlaps protected storage'
clone="$(jq -r .VolumeId "$work/created.json")"
cp "$work/created.json" "$record_path.restore-volume.json"
aws ec2 wait volume-available --volume-ids "$clone" --region "$region"
aws ec2 describe-volumes --volume-ids "$clone" --region "$region" --output json >"$work/clone.json"
jq -e --arg clone "$clone" --arg snapshot "$snapshot" --arg zone "$zone" '
    (.Volumes | length) == 1 and (.Volumes[0] | .VolumeId == $clone and .SnapshotId == $snapshot
      and .AvailabilityZone == $zone and .Encrypted == true and .State == "available" and .Attachments == []
      and any(.Tags[]; .Key == "Purpose" and .Value == "restore-check")
      and any(.Tags[]; .Key == "Environment" and .Value == "staging"))
' "$work/clone.json" >/dev/null || fail 'Diagnostic restore volume identity mismatch'
bash "$directory/check-replacement-hosts.sh" staging "$record" >/dev/null
bash "$directory/check-replacement-ip.sh" staging "$record" "$target" >/dev/null
aws ec2 attach-volume --volume-id "$clone" --instance-id "$instance" --device /dev/sdg --region "$region" --output json >/dev/null
aws ec2 wait volume-in-use --volume-ids "$clone" --region "$region"
ssh -i ../../morrowpal-staging-01.pem -o UserKnownHostsFile=environments/staging/known_hosts -o StrictHostKeyChecking=yes \
    "ec2-user@$ip" "sudo bash -s -- '$clone' '$uuid'" >"$record_path.restore-filesystem.json" <<'REMOTE'
set -Eeuo pipefail
volume="$1" expected="$2"
device=''
for attempt in {1..30}; do
    device="$(lsblk -ndo PATH,SERIAL | awk -v serial="${volume//-/}" '$2 == serial { print $1 }')"
    [[ -z "$device" ]] || break
    sleep 1
done
[[ "$device" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]
[[ "$(blkid -s TYPE -o value "$device")" == xfs && "$(blkid -s UUID -o value "$device")" == "$expected" ]]
mount_point="$(mktemp -d /mnt/morrowpal-restore.XXXXXX)"
trap 'mountpoint -q "$mount_point" && umount "$mount_point"; rmdir "$mount_point"' EXIT
mount -t xfs -o ro,nouuid,norecovery "$device" "$mount_point"
options="$(findmnt -n -o OPTIONS --mountpoint "$mount_point")"
[[ ",$options," == *,ro,* ]]
test -d "$mount_point/mysql"
restored="$(sha256sum "$mount_point/mysql/auto.cnf" | cut -d' ' -f1)"
current="$(sha256sum /var/lib/morrowpal/mysql/auto.cnf | cut -d' ' -f1)"
[[ "$restored" == "$current" ]]
jq -n --arg volume "$volume" --arg uuid "$expected" --arg hash "$restored" \
    '{restoredVolume:$volume,filesystem:"xfs",filesystemUuid:$uuid,mysqlIdentitySha256:$hash,readOnlyMount:true,mysqlIdentityMatches:true}'
REMOTE
aws ec2 detach-volume --volume-id "$clone" --instance-id "$instance" --region "$region" --output json >/dev/null
aws ec2 wait volume-available --volume-ids "$clone" --region "$region"
# Delete only the distinct, freshly created diagnostic volume after successful unmount/detach.
aws ec2 describe-volumes --volume-ids "$clone" --region "$region" --output json >"$work/delete.json"
jq -e --arg clone "$clone" --arg snapshot "$snapshot" '
    (.Volumes | length) == 1 and (.Volumes[0] | .VolumeId == $clone and .SnapshotId == $snapshot and .Attachments == []
      and .State == "available" and any(.Tags[]; .Key == "Purpose" and .Value == "restore-check"))
' "$work/delete.json" >/dev/null || fail 'Diagnostic cleanup identity/state mismatch'
aws ec2 delete-volume --volume-id "$clone" --region "$region"
aws ec2 wait volume-deleted --volume-ids "$clone" --region "$region"
printf 'Restored snapshot to a separate encrypted volume, verified XFS UUID and MySQL identity through a read-only mount, then removed the diagnostic volume.\n'
