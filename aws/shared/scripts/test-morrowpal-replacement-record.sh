#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
mkdir "$test_directory/bin"
export REPLACEMENT_TEST_DIRECTORY="$test_directory"
cat >"$test_directory/bin/ansible" <<'STUB'
#!/usr/bin/env bash
set -eu
environment=staging
for argument in "$@"; do
    [[ "$argument" != *environments/prod/vars.yml ]] || environment=prod
    if [[ "$argument" == src=* ]]; then
        destination="${argument#* dest=}"
        destination="${destination%% mode=*}"
    fi
done
cp "$REPLACEMENT_TEST_DIRECTORY/$environment.env" "$destination"
STUB
cat >"$test_directory/bin/aws" <<'STUB'
#!/usr/bin/env bash
touch "$REPLACEMENT_TEST_DIRECTORY/aws-called"
exit 99
STUB
chmod 0700 "$test_directory/bin/"*
export PATH="$test_directory/bin:$PATH"
validator="$script_directory/validate-replacement-record.sh"
count=0
for environment in staging prod; do
    region=us-east-1 ip=192.0.2.10 key=morrowpal-staging-01
    [[ "$environment" != prod ]] || { region=us-east-2; ip=192.0.2.20; key=01; }
    cat >"$test_directory/$environment.env" <<EOF
MORROWPAL_ENVIRONMENT=$environment
MORROWPAL_STACK_PREFIX=morrowpal-$environment
MORROWPAL_EC2_STACK_NAME=morrowpal-$environment-ec2
MORROWPAL_AWS_ACCOUNT_ID=123456789012
MORROWPAL_AWS_REGION=$region
MORROWPAL_AVAILABILITY_ZONE=${region}a
MORROWPAL_PUBLIC_IPV4=$ip
MORROWPAL_VPC_ID=vpc-12345678
MORROWPAL_SUBNET_ID=subnet-12345678
MORROWPAL_SECURITY_GROUP_ID=sg-12345678
MORROWPAL_EC2_KEY_NAME=$key
EOF
    jq -n --arg env "$environment" --arg region "$region" --arg ip "$ip" --arg key "$key" \
        --slurpfile policy "$script_directory/../ec2-image.json" '
        ("morrowpal-" + $env) as $prefix |
        ("sha256:" + ("a" * 64)) as $digest |
        {schemaVersion:1,environment:$env,accountId:"123456789012",region:$region,
         availabilityZone:($region+"a"),
         original:{stackName:($prefix+"-ec2"),instanceId:"i-12345678",amiId:"ami-12345678",rootVolumeId:"vol-12345678"},
         candidate:{stackName:($prefix+"-ec2-os-align-01"),instanceId:"i-23456789",amiId:"ami-23456789",
                    imageName:$policy[0].name,rootVolumeId:"vol-23456789"},
         data:{volumeId:"vol-34567890",filesystemUuid:"12345678-1234-1234-1234-123456789012",snapshotId:"snap-12345678"},
         publicIp:{allocationId:"eipalloc-12345678",address:$ip},
         network:{vpcId:"vpc-12345678",subnetId:"subnet-12345678",securityGroupId:"sg-12345678",keyName:$key},
         releases:{backend:{tag:"build-1-abcdef0",apiDigest:$digest,jobDigest:$digest},
                   app:{tag:"build-29-abcdef0",digest:$digest},website:{tag:"build-1-abcdef0",digest:$digest}},
         shutdown:(if $env == "staging" then {groupName:($prefix+"-auto-stop"),
                   scheduleName:($prefix+"-auto-stop-nightly"),originalTargetInstanceId:"i-12345678"} else null end)}
        ' >"$test_directory/valid.json"
    before="$(sha256sum "$test_directory/valid.json")"
    bash "$validator" "$environment" "$test_directory/valid.json" >"$test_directory/output"
    sed -i "s/^MORROWPAL_EC2_STACK_NAME=.*/MORROWPAL_EC2_STACK_NAME=morrowpal-$environment-ec2-os-align-01/" "$test_directory/$environment.env"
    bash "$validator" "$environment" "$test_directory/valid.json" >"$test_directory/output"
    [[ "$(sha256sum "$test_directory/valid.json")" == "$before" ]] || fail 'Record was modified'
    for mutation in \
        '.extra=true' 'del(.data)' '.schemaVersion=2' '.environment="other"' \
        '.accountId="999999999999"' '.region="us-west-2"' '.availabilityZone="us-west-2a"' \
        '.original.stackName="morrowpal-other-ec2"' '.candidate.stackName=.original.stackName' \
        '.candidate.instanceId=.original.instanceId' '.candidate.stackName+="--bad"' \
        '.candidate.stackName+=("a"*128)' '.original.instanceId="i-invalid"' \
        '.candidate.amiId="ami-invalid"' '.data.snapshotId="pending"' \
        '.data.filesystemUuid="unknown"' '.data.volumeId=.original.rootVolumeId' \
        '.candidate.rootVolumeId=.original.rootVolumeId' '.publicIp.address="192.0.2.99"' \
        '.publicIp.allocationId="eipalloc-invalid"' '.network.vpcId="vpc-87654321"' \
        '.network.subnetId="subnet-87654321"' '.network.securityGroupId="sg-87654321"' \
        '.network.keyName="wrong"' '.releases.backend.tag="latest"' \
        '.releases.backend.jobDigest="sha256:invalid"' '.releases.app.digest=null' \
        'del(.releases.website)' '.candidate.imageName="floating-latest"' \
        '.shutdown={groupName:"wrong",scheduleName:"wrong",originalTargetInstanceId:"i-87654321"}'; do
        jq "$mutation" "$test_directory/valid.json" >"$test_directory/invalid.json"
        if bash "$validator" "$environment" "$test_directory/invalid.json" >"$test_directory/output" 2>&1; then
            fail "Accepted invalid $environment record: $mutation"
        fi
        rg -q 'Replacement record is invalid' "$test_directory/output" || fail 'Unexpected failure'
        count=$((count+1))
    done
    for content in '{' '{} {}' ''; do
        printf '%s' "$content" >"$test_directory/invalid.json"
        if bash "$validator" "$environment" "$test_directory/invalid.json" >"$test_directory/output" 2>&1; then fail 'Accepted malformed record'; fi
    done
    sed -i "s/^MORROWPAL_EC2_STACK_NAME=.*/MORROWPAL_EC2_STACK_NAME=morrowpal-$environment-ec2-unrelated/" "$test_directory/$environment.env"
    if bash "$validator" "$environment" "$test_directory/valid.json" >"$test_directory/output" 2>&1; then fail 'Accepted unrelated active stack'; fi
done
if bash "$validator" >"$test_directory/output" 2>&1; then fail 'Accepted omitted environment'; fi
if bash "$validator" other "$test_directory/valid.json" >"$test_directory/output" 2>&1; then fail 'Accepted unknown environment'; fi
[[ ! -e "$test_directory/aws-called" ]] || fail 'Validator called AWS'
printf 'Replacement record tests passed: both environments, active hosts, %s field mismatches, malformed records and explicit selection; no AWS calls.\n' "$count"
