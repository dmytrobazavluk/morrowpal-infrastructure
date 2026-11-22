#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
export STORAGE_TEST_DIRECTORY="$test_directory"
mkdir "$test_directory/bin"
cat >"$test_directory/bin/ansible" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "$1" == localhost && "$*" == *'--connection local'* ]] || exit 99
for argument in "$@"; do
    if [[ "$argument" == src=* ]]; then
        destination="${argument#* dest=}"
        cp "$STORAGE_TEST_DIRECTORY/identity.env" "${destination%% mode=*}"
    fi
done
MOCK
cat >"$test_directory/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$STORAGE_TEST_DIRECTORY/calls"
[[ "$*" == *"--region $STORAGE_TEST_REGION"* ]] || exit 98
case "$1 $2" in
    'sts get-caller-identity') cat "$STORAGE_TEST_DIRECTORY/account"; exit ;;
    'cloudformation describe-stacks')
        [[ "$3 $4" == "--stack-name morrowpal-$STORAGE_TEST_ENVIRONMENT-mysql-storage" ]] || exit 97
        file=stack ;;
    'ec2 describe-volumes') [[ "$3 $4" == '--volume-ids vol-34567890' ]] || exit 97; file=volume ;;
    'ec2 describe-snapshots')
        [[ "$3 $4 $5 $6" == '--snapshot-ids snap-12345678 --owner-ids self' ]] || exit 97
        file=snapshot ;;
    *) printf 'Unexpected AWS operation\n' >&2; exit 99 ;;
esac
[[ "${STORAGE_TEST_API_FAILURE:-}" != "$file" ]] || exit 96
cat "$STORAGE_TEST_DIRECTORY/$file.json"
MOCK
chmod 0700 "$test_directory/bin/"*
export PATH="$test_directory/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION
checker="$script_directory/check-replacement-storage.sh"
count=0
for environment in staging prod; do
    export STORAGE_TEST_ENVIRONMENT="$environment" STORAGE_TEST_REGION=us-east-1
    [[ "$environment" != prod ]] || export STORAGE_TEST_REGION=us-east-2
    node --input-type=module - "$script_directory/../ec2-image.json" <<'NODE'
import fs from 'node:fs';
const dir=process.env.STORAGE_TEST_DIRECTORY,env=process.env.STORAGE_TEST_ENVIRONMENT,region=process.env.STORAGE_TEST_REGION;
const account='123456789012',prefix=`morrowpal-${env}`,zone=`${region}a`,stack=`${prefix}-mysql-storage`;
const stackId=`arn:aws:cloudformation:${region}:${account}:stack/${stack}/fixture-id`;
const policy=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const save=(name,value)=>fs.writeFileSync(`${dir}/${name}.json`,JSON.stringify(value));
const network={vpcId:'vpc-12345678',subnetId:'subnet-12345678',securityGroupId:'sg-12345678',keyName:env==='prod'?'01':`${prefix}-01`};
const record={schemaVersion:1,environment:env,accountId:account,region,availabilityZone:zone,
    original:{stackName:`${prefix}-ec2`,instanceId:'i-12345678',amiId:'ami-12345678',rootVolumeId:'vol-12345678'},
    candidate:{stackName:`${prefix}-ec2-os-align-01`,instanceId:'i-23456789',amiId:'ami-23456789',rootVolumeId:'vol-23456789',imageName:policy.name},
    data:{volumeId:'vol-34567890',filesystemUuid:'12345678-1234-1234-1234-123456789012',snapshotId:'snap-12345678'},
    publicIp:{allocationId:'eipalloc-12345678',address:'192.0.2.10'},network,
    releases:{backend:{tag:'build-1-abcdef0',apiDigest:`sha256:${'a'.repeat(64)}`,jobDigest:`sha256:${'b'.repeat(64)}`},
        app:{tag:'build-1-abcdef0',digest:`sha256:${'c'.repeat(64)}`},website:{tag:'build-1-abcdef0',digest:`sha256:${'d'.repeat(64)}`}},
    shutdown:env==='prod'?null:{groupName:`${prefix}-auto-stop`,scheduleName:`${prefix}-auto-stop-nightly`,originalTargetInstanceId:'i-12345678'}};
save('record',record);
const identity={MORROWPAL_ENVIRONMENT:env,MORROWPAL_STACK_PREFIX:prefix,MORROWPAL_EC2_STACK_NAME:record.original.stackName,
    MORROWPAL_AWS_ACCOUNT_ID:account,MORROWPAL_AWS_REGION:region,MORROWPAL_AVAILABILITY_ZONE:zone,
    MORROWPAL_PUBLIC_IPV4:record.publicIp.address,MORROWPAL_VPC_ID:network.vpcId,MORROWPAL_SUBNET_ID:network.subnetId,
    MORROWPAL_SECURITY_GROUP_ID:network.securityGroupId,MORROWPAL_EC2_KEY_NAME:network.keyName};
fs.writeFileSync(`${dir}/identity.env`,Object.entries(identity).map(([k,v])=>`${k}=${JSON.stringify(v)}`).join('\n'));
fs.writeFileSync(`${dir}/account`,account+'\n');
const tags={Environment:env,Application:'morrowpal'};
const tagList=tags=>Object.entries(tags).map(([Key,Value])=>({Key,Value}));
save('stack',{Stacks:[{StackId:stackId,StackStatus:'CREATE_COMPLETE',
    Outputs:[{OutputKey:'VolumeId',OutputValue:record.data.volumeId},{OutputKey:'DeviceName',OutputValue:'/dev/sdf'}],
    Parameters:[{ParameterKey:'AvailabilityZone',ParameterValue:zone},{ParameterKey:'AttachVolume',ParameterValue:'true'},
        {ParameterKey:'InstanceId',ParameterValue:record.original.instanceId}]}]});
const kms=`arn:aws:kms:${region}:${account}:key/fixture-key`;
save('volume',{Volumes:[{VolumeId:record.data.volumeId,AvailabilityZone:zone,Encrypted:true,VolumeType:'gp3',MultiAttachEnabled:false,
    KmsKeyId:kms,Size:10,State:'in-use',Tags:tagList({...tags,'aws:cloudformation:stack-name':stack,'aws:cloudformation:stack-id':stackId}),
    Attachments:[{VolumeId:record.data.volumeId,InstanceId:record.original.instanceId,Device:'/dev/sdf',State:'attached',DeleteOnTermination:false}]}]});
save('snapshot',{Snapshots:[{SnapshotId:record.data.snapshotId,OwnerId:account,VolumeId:record.data.volumeId,
    State:'completed',Encrypted:true,StorageTier:'standard',VolumeSize:10,KmsKeyId:kms,Tags:tagList(tags)}]});
NODE
    before="$(sha256sum "$test_directory/record.json")"
    bash "$checker" "$environment" "$test_directory/record.json" original >"$test_directory/output"
    reject() {
        local file="$test_directory/$1.json" mutation="$2" state="${3:-original}"
        cp "$file" "$test_directory/backup.json"
        jq "$mutation" "$file" >"$test_directory/mutated.json"
        cp "$test_directory/mutated.json" "$file"
        if bash "$checker" "$environment" "$test_directory/record.json" "$state" >"$test_directory/output" 2>&1; then fail "Accepted $1: $mutation"; fi
        rg -q 'Error:' "$test_directory/output" || fail 'Unexpected validation failure'
        cp "$test_directory/backup.json" "$file"
        count=$((count+1))
    }
    for mutation in '.Stacks=[]' '.Stacks[0].StackId="foreign"' '.Stacks[0].StackStatus="UPDATE_IN_PROGRESS"' \
        '.Stacks[0].Outputs[0].OutputValue="vol-87654321"' '.Stacks[0].Outputs[1].OutputValue="/dev/wrong"' \
        '.Stacks[0].Parameters[0].ParameterValue="wrong-az"' '.Stacks[0].Parameters[1].ParameterValue="false"' \
        '.Stacks[0].Parameters[2].ParameterValue="i-87654321"' 'del(.Stacks[0].Parameters[1])'; do reject stack "$mutation"; done
    for mutation in '.Volumes=[]' '.Volumes[0].VolumeId="vol-87654321"' '.Volumes[0].AvailabilityZone="wrong"' \
        '.Volumes[0].Encrypted=false' '.Volumes[0].VolumeType="gp2"' '.Volumes[0].MultiAttachEnabled=true' \
        '.Volumes[0].KmsKeyId=""' '.Volumes[0].Size=0' '.Volumes[0].Tags[0].Value="other"' \
        '.Volumes[0].Tags[3].Value="foreign-stack-id"' '.Volumes[0].State="available"' \
        '.Volumes[0].Attachments[0].InstanceId="i-23456789"' '.Volumes[0].Attachments[0].VolumeId="vol-87654321"' \
        '.Volumes[0].Attachments[0].Device="/dev/wrong"' '.Volumes[0].Attachments[0].State="detaching"' \
        '.Volumes[0].Attachments[0].DeleteOnTermination=true' '.Volumes[0].Attachments+=.Volumes[0].Attachments'; do reject volume "$mutation"; done
    for mutation in '.Snapshots=[]' '.Snapshots[0].SnapshotId="snap-87654321"' '.Snapshots[0].OwnerId="999999999999"' \
        '.Snapshots[0].VolumeId="vol-87654321"' '.Snapshots[0].State="pending"' '.Snapshots[0].Encrypted=false' \
        '.Snapshots[0].StorageTier="archive"' '.Snapshots[0].VolumeSize=9' '.Snapshots[0].KmsKeyId="other"' \
        '.Snapshots[0].Tags[0].Value="other"' 'del(.Snapshots[0].Tags)'; do reject snapshot "$mutation"; done
    # Explicit candidate and detached expectations require the matching stack and actual attachment.
    jq '.Stacks[0].Parameters[2].ParameterValue="i-23456789"' "$test_directory/stack.json" >"$test_directory/change.json"
    cp "$test_directory/change.json" "$test_directory/stack.json"
    jq '.Volumes[0].Attachments[0].InstanceId="i-23456789"' "$test_directory/volume.json" >"$test_directory/change.json"
    cp "$test_directory/change.json" "$test_directory/volume.json"
    bash "$checker" "$environment" "$test_directory/record.json" candidate >"$test_directory/output"
    reject volume '.Volumes[0].Attachments[0].InstanceId="i-12345678"' candidate
    jq '.Stacks[0].Parameters[1].ParameterValue="false"' "$test_directory/stack.json" >"$test_directory/change.json"
    cp "$test_directory/change.json" "$test_directory/stack.json"
    jq '.Volumes[0] |= (.State="available" | .Attachments=[])' "$test_directory/volume.json" >"$test_directory/change.json"
    cp "$test_directory/change.json" "$test_directory/volume.json"
    bash "$checker" "$environment" "$test_directory/record.json" detached >"$test_directory/output"
    reject volume '.Volumes[0].State="in-use"' detached
    reject volume '.Volumes[0].Attachments=[{InstanceId:"i-12345678"}]' detached
    reject stack '.Stacks[0].Parameters[1].ParameterValue="true"' detached
    [[ "$(sha256sum "$test_directory/record.json")" == "$before" ]] || fail 'Record modified'
    export STORAGE_TEST_API_FAILURE=snapshot
    if bash "$checker" "$environment" "$test_directory/record.json" detached >"$test_directory/output" 2>&1; then fail 'Ignored AWS error'; fi
    unset STORAGE_TEST_API_FAILURE
    : >"$test_directory/calls"
    if AWS_REGION=us-west-2 bash "$checker" "$environment" "$test_directory/record.json" detached >"$test_directory/output" 2>&1; then fail 'Accepted Region mismatch'; fi
    reject record '.environment="other"' detached
    if bash "$checker" "$environment" "$test_directory/record.json" automatic >"$test_directory/output" 2>&1; then fail 'Accepted invalid attachment selection'; fi
    if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted omitted attachment selection'; fi
    [[ ! -s "$test_directory/calls" ]] || fail 'Invalid local input called AWS'
    printf '999999999999\n' >"$test_directory/account"
    if bash "$checker" "$environment" "$test_directory/record.json" detached >"$test_directory/output" 2>&1; then fail 'Accepted wrong caller account'; fi
    [[ "$(wc -l <"$test_directory/calls")" == 1 ]] || fail 'Wrong account continued querying resources'
    printf '%s storage checks passed.\n' "$environment"
done
printf 'Replacement storage tests passed: all three attachment states in both environments and %s mismatches, using only mocked AWS reads.\n' "$count"
