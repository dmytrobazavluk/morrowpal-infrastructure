#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
export IP_TEST_DIRECTORY="$test_directory"
mkdir "$test_directory/bin"
cat >"$test_directory/bin/ansible" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "$1" == localhost && "$*" == *'--connection local'* ]] || exit 99
for argument in "$@"; do
    if [[ "$argument" == src=* ]]; then
        destination="${argument#* dest=}"
        cp "$IP_TEST_DIRECTORY/identity.env" "${destination%% mode=*}"
    fi
done
MOCK
cat >"$test_directory/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$IP_TEST_DIRECTORY/calls"
[[ "$*" == *"--region $IP_TEST_REGION"* ]] || exit 98
case "$1 $2" in
    'sts get-caller-identity') cat "$IP_TEST_DIRECTORY/account"; exit ;;
    'cloudformation describe-stacks')
        [[ "$3" == --stack-name ]] || exit 97
        case "$4" in
            "morrowpal-$IP_TEST_ENVIRONMENT-public-ip") file=stack ;;
            "morrowpal-$IP_TEST_ENVIRONMENT-ec2") file=original-stack ;;
            "morrowpal-$IP_TEST_ENVIRONMENT-ec2-os-align-01") file=candidate-stack ;;
            *) exit 97 ;;
        esac ;;
    'ec2 describe-addresses') [[ "$3 $4" == '--allocation-ids eipalloc-12345678' ]] || exit 97; file=address ;;
    'ec2 describe-network-interfaces') [[ "$3 $4" == '--network-interface-ids eni-12345678' ]] || exit 97; file=interface ;;
    *) printf 'Unexpected AWS operation\n' >&2; exit 99 ;;
esac
[[ "${IP_TEST_API_FAILURE:-}" != "$file" ]] || exit 96
cat "$IP_TEST_DIRECTORY/$file.json"
MOCK
chmod 0700 "$test_directory/bin/"*
export PATH="$test_directory/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION
checker="$script_directory/check-replacement-ip.sh"
count=0
for environment in staging prod; do
    export IP_TEST_ENVIRONMENT="$environment" IP_TEST_REGION=us-east-1
    [[ "$environment" != prod ]] || export IP_TEST_REGION=us-east-2
    node --input-type=module - "$script_directory/../ec2-image.json" <<'NODE'
import fs from 'node:fs';
const dir=process.env.IP_TEST_DIRECTORY,env=process.env.IP_TEST_ENVIRONMENT,region=process.env.IP_TEST_REGION;
const account='123456789012',prefix=`morrowpal-${env}`,zone=`${region}a`,stack=`${prefix}-public-ip`;
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
const stackId=name=>`arn:aws:cloudformation:${region}:${account}:stack/${name}/fixture-id`;
save('stack',{Stacks:[{StackId:stackId(stack),StackStatus:'CREATE_COMPLETE',
    Outputs:[{OutputKey:'AllocationId',OutputValue:record.publicIp.allocationId},{OutputKey:'PublicIp',OutputValue:record.publicIp.address}],
    Parameters:[{ParameterKey:'InstanceId',ParameterValue:record.original.instanceId}]}]});
for(const host of ['original','candidate']) save(`${host}-stack`,{Stacks:[{StackId:stackId(record[host].stackName),StackStatus:'CREATE_COMPLETE',
    Outputs:[{OutputKey:'InstanceId',OutputValue:record[host].instanceId},{OutputKey:'AvailabilityZone',OutputValue:zone}]}]});
const tags={Environment:env,Application:'morrowpal','aws:cloudformation:stack-name':stack,'aws:cloudformation:stack-id':stackId(stack)};
const association={AllocationId:record.publicIp.allocationId,AssociationId:'eipassoc-12345678',PublicIp:record.publicIp.address};
save('address',{Addresses:[{...association,Domain:'vpc',InstanceId:record.original.instanceId,NetworkInterfaceOwnerId:account,
    NetworkInterfaceId:'eni-12345678',PrivateIpAddress:'10.0.0.10',Tags:Object.entries(tags).map(([Key,Value])=>({Key,Value}))}]});
save('interface',{NetworkInterfaces:[{NetworkInterfaceId:'eni-12345678',OwnerId:account,VpcId:network.vpcId,SubnetId:network.subnetId,
    AvailabilityZone:zone,Groups:[{GroupId:network.securityGroupId}],Status:'in-use',
    Attachment:{InstanceId:record.original.instanceId,DeviceIndex:0,Status:'attached'},PrivateIpAddress:'10.0.0.10',Association:association,
    PrivateIpAddresses:[{Primary:true,PrivateIpAddress:'10.0.0.10'}]}]});
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
        '.Stacks[0].Outputs[0].OutputValue="eipalloc-87654321"' '.Stacks[0].Outputs[1].OutputValue="192.0.2.99"' \
        '.Stacks[0].Parameters[0].ParameterValue="i-23456789"' 'del(.Stacks[0].Parameters)'; do reject stack "$mutation"; done
    for mutation in '.Stacks[0].StackId="foreign"' '.Stacks[0].StackStatus="DELETE_COMPLETE"' \
        '.Stacks[0].Outputs[0].OutputValue="i-87654321"' '.Stacks[0].Outputs[1].OutputValue="wrong-az"'; do reject original-stack "$mutation"; done
    for mutation in '.Addresses=[]' '.Addresses[0].AllocationId="eipalloc-87654321"' '.Addresses[0].PublicIp="192.0.2.99"' \
        '.Addresses[0].Domain="standard"' '.Addresses[0].InstanceId="i-23456789"' \
        '.Addresses[0].NetworkInterfaceOwnerId="999999999999"' 'del(.Addresses[0].AssociationId)' \
        '.Addresses[0].NetworkInterfaceId="eni-invalid"' '.Addresses[0].Tags[0].Value="other"' \
        '.Addresses[0].Tags[3].Value="foreign-stack-id"'; do reject address "$mutation"; done
    for mutation in '.NetworkInterfaces=[]' '.NetworkInterfaces[0].NetworkInterfaceId="eni-87654321"' \
        '.NetworkInterfaces[0].OwnerId="999999999999"' '.NetworkInterfaces[0].VpcId="vpc-87654321"' \
        '.NetworkInterfaces[0].SubnetId="subnet-87654321"' '.NetworkInterfaces[0].AvailabilityZone="wrong-az"' \
        '.NetworkInterfaces[0].Groups[0].GroupId="sg-87654321"' '.NetworkInterfaces[0].Status="available"' \
        '.NetworkInterfaces[0].Attachment.Status="detaching"' '.NetworkInterfaces[0].Attachment.InstanceId="i-23456789"' \
        '.NetworkInterfaces[0].Attachment.DeviceIndex=1' '.NetworkInterfaces[0].PrivateIpAddress="10.0.0.99"' \
        '.NetworkInterfaces[0].Association.AllocationId="eipalloc-87654321"' \
        '.NetworkInterfaces[0].Association.AssociationId="eipassoc-87654321"' '.NetworkInterfaces[0].Association.PublicIp="192.0.2.99"' \
        '.NetworkInterfaces[0].PrivateIpAddresses[0].Primary=false'; do reject interface "$mutation"; done
    # The same allocation and address can be checked on the candidate, without changing the active overlay.
    for file in stack address interface; do
        case "$file" in
            stack) mutation='.Stacks[0].Parameters[0].ParameterValue="i-23456789"' ;;
            address) mutation='.Addresses[0].InstanceId="i-23456789"' ;;
            interface) mutation='.NetworkInterfaces[0].Attachment.InstanceId="i-23456789"' ;;
        esac
        jq "$mutation" "$test_directory/$file.json" >"$test_directory/change.json"
        cp "$test_directory/change.json" "$test_directory/$file.json"
    done
    bash "$checker" "$environment" "$test_directory/record.json" candidate >"$test_directory/output"
    reject address '.Addresses[0].InstanceId="i-12345678"' candidate
    reject candidate-stack '.Stacks[0].Outputs[0].OutputValue="i-12345678"' candidate
    [[ "$(sha256sum "$test_directory/record.json")" == "$before" ]] || fail 'Record modified'
    for api in stack candidate-stack address interface; do
        export IP_TEST_API_FAILURE="$api"
        if bash "$checker" "$environment" "$test_directory/record.json" candidate >"$test_directory/output" 2>&1; then fail 'Ignored AWS error'; fi
    done
    unset IP_TEST_API_FAILURE
    : >"$test_directory/calls"
    for variable in AWS_REGION AWS_DEFAULT_REGION; do
        if env "$variable=us-west-2" bash "$checker" "$environment" "$test_directory/record.json" candidate >"$test_directory/output" 2>&1; then fail 'Accepted Region mismatch'; fi
    done
    reject record '.environment="other"' candidate
    for selection in detached automatic; do
        if bash "$checker" "$environment" "$test_directory/record.json" "$selection" >"$test_directory/output" 2>&1; then fail 'Accepted invalid attachment selection'; fi
    done
    if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted omitted attachment selection'; fi
    [[ ! -s "$test_directory/calls" ]] || fail 'Invalid local input called AWS'
    printf '999999999999\n' >"$test_directory/account"
    if bash "$checker" "$environment" "$test_directory/record.json" candidate >"$test_directory/output" 2>&1; then fail 'Accepted wrong caller account'; fi
    [[ "$(wc -l <"$test_directory/calls")" == 1 ]] || fail 'Wrong account continued querying resources'
    printf '%s Elastic IP checks passed.\n' "$environment"
done
printf 'Replacement Elastic IP tests passed: both hosts in both environments and %s mismatches, using only mocked AWS reads.\n' "$count"
