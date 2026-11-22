#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
export REPLACEMENT_HOST_TEST="$test_directory"
mkdir "$test_directory/bin"
cat >"$test_directory/bin/ansible" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "$1" == localhost && "$*" == *'--connection local'* ]] || exit 99
for argument in "$@"; do
    if [[ "$argument" == src=* ]]; then
        destination="${argument#* dest=}"
        cp "$REPLACEMENT_HOST_TEST/identity.env" "${destination%% mode=*}"
    fi
done
MOCK
cat >"$test_directory/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$REPLACEMENT_HOST_TEST/calls"
[[ "$*" == *"--region $REPLACEMENT_REGION"* ]] || exit 98
operation="$1 $2"
shift 2
case "$operation" in
    'sts get-caller-identity') cat "$REPLACEMENT_HOST_TEST/account"; exit ;;
    'cloudformation describe-stacks')
        [[ "$1" == --stack-name ]] || exit 97
        file="stack-$2" ;;
    'iam get-instance-profile') file=profile ;;
    'ec2 describe-instances')
        [[ "$1" == --instance-ids ]] || exit 97
        file="instance-$2" ;;
    'ec2 describe-volumes')
        [[ "$1" == --volume-ids ]] || exit 97
        file="volume-$2" ;;
    'ec2 describe-images')
        [[ "$*" == *--include-deprecated* ]] || exit 97
        file=image ;;
    *) printf 'Unexpected AWS operation\n' >&2; exit 99 ;;
esac
[[ "${REPLACEMENT_API_FAILURE:-}" != "$file" ]] || exit 96
cat "$REPLACEMENT_HOST_TEST/$file.json"
MOCK
chmod 0700 "$test_directory/bin/"*
export PATH="$test_directory/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION
checker="$script_directory/check-replacement-hosts.sh"
count=0
for environment in staging prod; do
    export REPLACEMENT_ENVIRONMENT="$environment"
    export REPLACEMENT_REGION=us-east-1
    [[ "$environment" != prod ]] || export REPLACEMENT_REGION=us-east-2
    node --input-type=module - "$script_directory/../ec2-image.json" <<'NODE'
import fs from 'node:fs';
const directory=process.env.REPLACEMENT_HOST_TEST, env=process.env.REPLACEMENT_ENVIRONMENT;
const region=process.env.REPLACEMENT_REGION, account='123456789012', prefix=`morrowpal-${env}`, zone=`${region}a`;
const policy=JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const save=(name, data)=>fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(data));
const profile=`arn:aws:iam::${account}:instance-profile/${prefix}`;
const role=`arn:aws:iam::${account}:role/${prefix}`;
const network={vpcId:'vpc-12345678',subnetId:'subnet-12345678',securityGroupId:'sg-12345678',keyName:env==='prod'?'01':`${prefix}-01`};
const original={stackName:`${prefix}-ec2`,instanceId:'i-12345678',amiId:'ami-12345678',rootVolumeId:'vol-12345678'};
const candidate={stackName:`${prefix}-ec2-os-align-01`,instanceId:'i-23456789',amiId:'ami-23456789',rootVolumeId:'vol-23456789',imageName:policy.name};
const digest=`sha256:${'a'.repeat(64)}`, tag='build-1-abcdef0';
const record={schemaVersion:1,environment:env,accountId:account,region,availabilityZone:zone,original,candidate,
    data:{volumeId:'vol-34567890',filesystemUuid:'12345678-1234-1234-1234-123456789012',snapshotId:'snap-12345678'},
    publicIp:{allocationId:'eipalloc-12345678',address:'192.0.2.10'},network,
    releases:{backend:{tag,apiDigest:digest,jobDigest:digest},app:{tag,digest},website:{tag,digest}},
    shutdown:env==='staging'?{groupName:`${prefix}-auto-stop`,scheduleName:`${prefix}-auto-stop-nightly`,originalTargetInstanceId:original.instanceId}:null};
save('record',record);
const identity={MORROWPAL_ENVIRONMENT:env,MORROWPAL_STACK_PREFIX:prefix,MORROWPAL_EC2_STACK_NAME:original.stackName,
    MORROWPAL_AWS_ACCOUNT_ID:account,MORROWPAL_AWS_REGION:region,MORROWPAL_AVAILABILITY_ZONE:zone,
    MORROWPAL_PUBLIC_IPV4:record.publicIp.address,MORROWPAL_VPC_ID:network.vpcId,MORROWPAL_SUBNET_ID:network.subnetId,
    MORROWPAL_SECURITY_GROUP_ID:network.securityGroupId,MORROWPAL_EC2_KEY_NAME:network.keyName};
fs.writeFileSync(`${directory}/identity.env`,Object.entries(identity).map(([k,v])=>`${k}=${JSON.stringify(v)}`).join('\n'));
fs.writeFileSync(`${directory}/account`,account+'\n');
function stack(name,outputs) {
    const StackId=`arn:aws:cloudformation:${region}:${account}:stack/${name}/fixture-id`;
    save(`stack-${name}`,{Stacks:[{StackId,StackStatus:'CREATE_COMPLETE',Outputs:Object.entries(outputs).map(([OutputKey,OutputValue])=>({OutputKey,OutputValue}))}]});
    return StackId;
}
stack(`${prefix}-ec2-access`,{InstanceProfileArn:profile,RoleArn:role});
save('profile',{InstanceProfile:{Arn:profile,Roles:[{Arn:role}]}});
for(const host of [original,candidate]) {
    const stackId=stack(host.stackName,{InstanceId:host.instanceId,AvailabilityZone:zone});
    const tags={Environment:env,Application:'morrowpal',Name:`${prefix}-01`,'aws:cloudformation:stack-name':host.stackName,'aws:cloudformation:stack-id':stackId};
    save(`instance-${host.instanceId}`,{Reservations:[{OwnerId:account,Instances:[{InstanceId:host.instanceId,ImageId:host.amiId,
        VpcId:network.vpcId,SubnetId:network.subnetId,SecurityGroups:[{GroupId:network.securityGroupId}],Placement:{AvailabilityZone:zone},
        KeyName:network.keyName,IamInstanceProfile:{Arn:profile},State:{Name:'stopped'},Tags:Object.entries(tags).map(([Key,Value])=>({Key,Value})),
        RootDeviceType:'ebs',RootDeviceName:'/dev/xvda',BlockDeviceMappings:[{DeviceName:'/dev/xvda',Ebs:{VolumeId:host.rootVolumeId,Status:'attached'}}]}]}]});
    save(`volume-${host.rootVolumeId}`,{Volumes:[{VolumeId:host.rootVolumeId,AvailabilityZone:zone,Encrypted:true,VolumeType:'gp3',State:'in-use',
        Attachments:[{VolumeId:host.rootVolumeId,InstanceId:host.instanceId,Device:'/dev/xvda',State:'attached'}]}]});
}
save('image',{Images:[{ImageId:candidate.amiId,Name:policy.name,OwnerId:policy.ownerId,Architecture:policy.architecture,
    RootDeviceType:'ebs',VirtualizationType:'hvm',State:'available',DeprecationTime:'2026-11-01T17:47:00Z'}]});
NODE
    before="$(sha256sum "$test_directory/record.json")"
    bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output"
    [[ "$(sha256sum "$test_directory/record.json")" == "$before" ]] || fail 'Record modified'
    reject() {
        local file="$test_directory/$1.json" mutation="$2"
        cp "$file" "$test_directory/backup.json"
        jq "$mutation" "$file" >"$test_directory/mutated.json"
        cp "$test_directory/mutated.json" "$file"
        if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail "Accepted $1 $mutation"; fi
        rg -q 'Error:' "$test_directory/output" || fail 'Unexpected validation failure'
        cp "$test_directory/backup.json" "$file"
        count=$((count+1))
    }
    for host in '12345678' '23456789'; do
        stack="morrowpal-$environment-ec2"
        [[ "$host" != 23456789 ]] || stack+=-os-align-01
        reject "stack-$stack" '.Stacks[0].StackStatus="UPDATE_IN_PROGRESS"'
        reject "stack-$stack" '.Stacks[0].StackId="arn:aws:cloudformation:wrong:999999999999:stack/foreign/id"'
        reject "stack-$stack" '.Stacks[0].Outputs[0].OutputValue="i-87654321"'
        for mutation in \
            '.Reservations=[]' '.Reservations[0].OwnerId="999999999999"' \
            '.Reservations[0].Instances[0].InstanceId="i-87654321"' \
            '.Reservations[0].Instances[0].ImageId="ami-87654321"' \
            '.Reservations[0].Instances[0].VpcId="vpc-87654321"' \
            '.Reservations[0].Instances[0].SubnetId="subnet-87654321"' \
            '.Reservations[0].Instances[0].SecurityGroups[0].GroupId="sg-87654321"' \
            '.Reservations[0].Instances[0].Placement.AvailabilityZone="wrong"' \
            '.Reservations[0].Instances[0].KeyName="wrong"' \
            '.Reservations[0].Instances[0].IamInstanceProfile.Arn="wrong"' \
            '.Reservations[0].Instances[0].State.Name="terminated"' \
            '.Reservations[0].Instances[0].Tags[0].Value="other"' \
            '.Reservations[0].Instances[0].Tags[4].Value="wrong-stack-id"' \
            '.Reservations[0].Instances[0].RootDeviceType="instance-store"' \
            '.Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId="vol-87654321"'; do
            reject "instance-i-$host" "$mutation"
        done
        for mutation in '.Volumes=[]' '.Volumes[0].Encrypted=false' '.Volumes[0].AvailabilityZone="wrong"' \
            '.Volumes[0].VolumeId="vol-87654321"' '.Volumes[0].VolumeType="gp2"' \
            '.Volumes[0].Attachments[0].InstanceId="i-87654321"' '.Volumes[0].Attachments[0].Device="/dev/wrong"' \
            '.Volumes[0].Attachments[0].State="detaching"'; do
            reject "volume-vol-$host" "$mutation"
        done
    done
    reject profile '.InstanceProfile.Roles[0].Arn="wrong"'
    reject "stack-morrowpal-$environment-ec2-access" '.Stacks[0].Outputs[0].OutputValue="arn:aws:iam::999999999999:instance-profile/other"'
    for mutation in '.Images=[]' '.Images[0].ImageId="ami-87654321"' '.Images[0].Name="floating-latest"' \
        '.Images[0].OwnerId="999999999999"' '.Images[0].Architecture="arm64"' '.Images[0].State="disabled"' \
        '.Images[0].ImageAllowed=false'; do reject image "$mutation"; done
    export REPLACEMENT_API_FAILURE=image
    if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Ignored AWS failure'; fi
    unset REPLACEMENT_API_FAILURE
    : >"$test_directory/calls"
    if AWS_REGION=us-west-2 bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted Region mismatch'; fi
    [[ ! -s "$test_directory/calls" ]] || fail 'Region mismatch called AWS'
    reject record '.candidate.stackName="morrowpal-other-ec2"'
    [[ ! -s "$test_directory/calls" ]] || fail 'Invalid record called AWS'
    printf '999999999999\n' >"$test_directory/account"
    if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted wrong caller account'; fi
    [[ "$(wc -l <"$test_directory/calls")" == 1 ]] || fail 'Wrong account continued querying resources'
done
printf 'Replacement host checks passed for both environments and %s mismatches; only mocked read-only AWS calls used.\n' "$count"
