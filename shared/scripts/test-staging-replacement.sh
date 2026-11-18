#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
export REPLACEMENT_TEST_ROOT="$work/infrastructure"
root="$REPLACEMENT_TEST_ROOT"
mkdir -p "$root/shared/scripts" "$root/shared/runtime" "$root/environments/staging" "$root/bin"
cp "$directory/"{staging-host-handoff.sh,prepare-staging-replacement.sh,verify-staging-snapshot-restore.sh,execute-staging-replacement-change-set.sh,validate-replacement-record.sh,check-replacement-shutdown.sh,test-replacement-aws.mjs} "$root/shared/scripts/"
cp "$directory/../ec2-image.json" "$root/shared/"
# Keep offline lock tests independent from any real staging operation in progress.
sed -i "s|/tmp/morrowpal-staging-host-handoff.lock|$root/handoff.lock|g" "$root/shared/scripts/staging-host-handoff.sh" "$root/shared/scripts/prepare-staging-replacement.sh"
sed -i "s|/tmp/morrowpal-staging-host-handoff.lock|$root/handoff.lock|g" "$root/shared/scripts/verify-staging-snapshot-restore.sh"
node --input-type=module - "$root" <<'NODE'
import fs from 'node:fs';
const root=process.argv[2],policy=JSON.parse(fs.readFileSync(`${root}/shared/ec2-image.json`));
const r={schemaVersion:1,environment:'staging',accountId:'123456789012',region:'us-east-1',availabilityZone:'us-east-1a',
 original:{stackName:'morrowpal-staging-ec2',instanceId:'i-12345678',amiId:'ami-12345678',rootVolumeId:'vol-12345678'},
 candidate:{stackName:'morrowpal-staging-ec2-align',instanceId:'i-23456789',amiId:'ami-23456789',rootVolumeId:'vol-23456789',imageName:policy.name},
 data:{volumeId:'vol-34567890',filesystemUuid:'12345678-1234-1234-1234-123456789012',snapshotId:'snap-12345678'},
 publicIp:{allocationId:'eipalloc-12345678',address:'192.0.2.10'},network:{vpcId:'vpc-12345678',subnetId:'subnet-12345678',securityGroupId:'sg-12345678',keyName:'morrowpal-staging-01'},
 releases:{backend:{tag:'build-1-abcdef0',apiDigest:`sha256:${'a'.repeat(64)}`,jobDigest:`sha256:${'b'.repeat(64)}`},app:{tag:'build-1-abcdef0',digest:`sha256:${'c'.repeat(64)}`},website:{tag:'build-1-abcdef0',digest:`sha256:${'d'.repeat(64)}`}},
 shutdown:{groupName:'morrowpal-staging-auto-stop',scheduleName:'morrowpal-staging-auto-stop-nightly',originalTargetInstanceId:'i-12345678'}};
fs.writeFileSync(`${root}/baseline.json`,JSON.stringify(r));
const env={MORROWPAL_ENVIRONMENT:'staging',MORROWPAL_STACK_PREFIX:'morrowpal-staging',MORROWPAL_AWS_ACCOUNT_ID:r.accountId,MORROWPAL_AWS_REGION:r.region,MORROWPAL_AVAILABILITY_ZONE:r.availabilityZone,MORROWPAL_PUBLIC_IPV4:r.publicIp.address,MORROWPAL_VPC_ID:r.network.vpcId,MORROWPAL_SUBNET_ID:r.network.subnetId,MORROWPAL_SECURITY_GROUP_ID:r.network.securityGroupId,MORROWPAL_EC2_KEY_NAME:r.network.keyName};
fs.writeFileSync(`${root}/identity.env`,Object.entries(env).map(([k,v])=>`${k}=${JSON.stringify(v)}`).join('\n')+'\n');
NODE
cat >"$root/bin/ansible" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "$1" == localhost ]] || exit 99
for arg in "$@"; do
 if [[ "$arg" == src=* ]]; then
  destination="${arg#* dest=}"; destination="${destination%% mode=*}"
  cp "$REPLACEMENT_TEST_ROOT/identity.env" "$destination"
  awk '$1 == "morrowpal_ec2_stack_name:" { print "MORROWPAL_EC2_STACK_NAME=" $2 }' "$REPLACEMENT_TEST_ROOT/environments/staging/vars.yml" >>"$destination"
 fi
done
MOCK
cat >"$root/bin/aws" <<'MOCK'
#!/usr/bin/env bash
exec node "$REPLACEMENT_TEST_ROOT/shared/scripts/test-replacement-aws.mjs" "$@"
MOCK
cat >"$root/shared/scripts/morrowpal-infrastructure-change-set.sh" <<'MOCK'
#!/usr/bin/env bash
exec node "$REPLACEMENT_TEST_ROOT/shared/scripts/test-replacement-aws.mjs" prepare "$@"
MOCK
for checker in hosts storage ip images; do
    printf '#!/usr/bin/env bash\nset -eu\ntest ! -e "$REPLACEMENT_TEST_ROOT/reject-check"\n' >"$root/shared/scripts/check-replacement-$checker.sh"
done
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
reset() {
 cp "$root/baseline.json" "$root/record.json"
 printf 'morrowpal_ec2_stack_name: morrowpal-staging-ec2\n' >"$root/environments/staging/vars.yml"
 printf '%s\n' '{"storage":"original","ip":"original","shutdown":"original","scheduleState":"ENABLED","executed":[],"snapshots":0}' >"$root/state.json"
 : >"$root/calls"
 rm -f "$root/reject-check"
}
change() { jq "$1" "$root/state.json" >"$root/new.json"; mv "$root/new.json" "$root/state.json"; }
shutdown="$root/shared/scripts/check-replacement-shutdown.sh"
handoff="$root/shared/scripts/staging-host-handoff.sh"
reset
for target in original candidate; do
 for state in ENABLED DISABLED; do
  change ".shutdown=\"$target\" | .scheduleState=\"$state\""
  bash "$shutdown" staging "$root/record.json" "$target" "$state" >"$work/output"
 done
done
for mutation in '.badCron=true' '.force=true' '.badTrust=true' '.extraPolicy=true' '.managedPolicy=true' '.wildcard=true' '.badTag=true' '.stackStatus="UPDATE_IN_PROGRESS"' '.wrongAccount=true'; do
 reset; change "$mutation"
 if bash "$shutdown" staging "$root/record.json" original ENABLED >"$work/output" 2>&1; then fail "Shutdown accepted $mutation"; fi
done
reset
if bash "$shutdown" prod "$root/record.json" original ENABLED >"$work/output" 2>&1; then fail 'Shutdown accepted prod'; fi
[[ ! -s "$root/calls" ]] || fail 'Prod shutdown called AWS'
reset
bash "$handoff" "$root/record.json" candidate >"$work/output"
jq -e '.executed == [] and .snapshots == 0' "$root/state.json" >/dev/null
for mutation in '.runningHost="original"' '.runningHost="candidate"' '.wrongAccount=true'; do
 reset; change "$mutation"
 if bash "$handoff" "$root/record.json" candidate --execute >"$work/output" 2>&1; then fail "Handoff accepted $mutation"; fi
 jq -e '.executed == [] and .snapshots == 0' "$root/state.json" >/dev/null
done
reset
touch "$root/reject-check"
if bash "$handoff" "$root/record.json" candidate --execute >"$work/output" 2>&1; then fail 'Handoff ignored failed checker'; fi
jq -e '.executed == [] and .snapshots == 0' "$root/state.json" >/dev/null
reset
bash "$handoff" "$root/record.json" candidate --execute >"$work/output"
jq -e '.storage == "candidate" and .ip == "candidate" and .shutdown == "candidate" and .scheduleState == "DISABLED" and .snapshots == 1' "$root/state.json" >/dev/null
if bash "$root/shared/scripts/prepare-staging-replacement.sh" "$root/record.json" candidate staging@example.com >"$work/output" 2>&1; then fail 'Preparation ignored scheduler retry window'; fi
rg -q 'paused scheduler retry window' "$work/output" || fail 'Preparation rejected the retry window for an unexpected reason'
bash "$handoff" "$root/record.json" candidate --enable-shutdown >"$work/output"
jq -e '.scheduleState == "ENABLED"' "$root/state.json" >/dev/null
bash "$handoff" "$root/record.json" original --execute >"$work/output"
jq -e '.storage == "original" and .ip == "original" and .shutdown == "original" and .scheduleState == "DISABLED" and .snapshots == 2' "$root/state.json" >/dev/null
for failure in public-ip attach; do
 reset; change ".failOperation=\"$failure\""
 if bash "$handoff" "$root/record.json" candidate --execute >"$work/output" 2>&1; then fail "Ignored $failure failure"; fi
 jq -e '.storage == "detached" and .scheduleState == "DISABLED" and .runningHost == null' "$root/state.json" >/dev/null
 change 'del(.failOperation)'
 bash "$handoff" "$root/record.json" original --execute >"$work/output"
 jq -e '.storage == "original" and .ip == "original" and .shutdown == "original"' "$root/state.json" >/dev/null
done
reset; change '.unsafeChange=true'
if bash "$handoff" "$root/record.json" candidate --execute >"$work/output" 2>&1; then fail 'Executed a protected resource replacement'; fi
jq -e '.executed == [] and .snapshots == 0' "$root/state.json" >/dev/null
reset; change '.foreignEnvironment=true'
if bash "$handoff" "$root/record.json" candidate --execute >"$work/output" 2>&1; then fail 'Executed a prod change set'; fi
jq -e '.executed == []' "$root/state.json" >/dev/null
node --input-type=module - "$work" <<'NODE'
import fs from 'node:fs';
const directory=process.argv[2];
const block='boot log\n-----BEGIN SSH HOST KEY KEYS-----\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture root@host\n-----END SSH HOST KEY KEYS-----\n';
fs.writeFileSync(`${directory}/plain.json`,JSON.stringify({Output:block}));
fs.writeFileSync(`${directory}/encoded.json`,JSON.stringify({Output:Buffer.from(block).toString('base64')}));
fs.writeFileSync(`${directory}/invalid.json`,JSON.stringify({Output:'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture authorized-user-key'}));
NODE
node "$directory/ssh-host-keys-from-console.mjs" <"$work/plain.json" >"$work/plain.keys"
node "$directory/ssh-host-keys-from-console.mjs" <"$work/encoded.json" >"$work/encoded.keys"
cmp "$work/plain.keys" "$work/encoded.keys"
if node "$directory/ssh-host-keys-from-console.mjs" <"$work/invalid.json" >"$work/output" 2>&1; then fail 'Trusted an SSH key outside the host-key console block'; fi
reset
if bash "$root/shared/scripts/verify-staging-snapshot-restore.sh" "$root/record.json" original >"$work/output" 2>&1; then fail 'Restore check accepted a protected volume ID'; fi
rg -q 'overlaps protected storage' "$work/output" || fail 'Restore check failed for the wrong reason'
if rg -q 'ec2 (attach-volume|detach-volume|delete-volume)' "$root/calls"; then fail 'Restore check touched protected storage'; fi
printf 'Replacement shutdown, exact change-set gates, stopped-host guards, dry run, both handoff directions and partial-failure return to original passed offline.\n'
