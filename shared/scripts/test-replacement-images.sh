#!/usr/bin/env bash
set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
export IMAGE_TEST_DIRECTORY="$test_directory"
mkdir "$test_directory/bin"
cat >"$test_directory/bin/ansible" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "$1" == localhost && "$*" == *'--connection local'* ]] || exit 99
for argument in "$@"; do
    if [[ "$argument" == src=* ]]; then
        destination="${argument#* dest=}"
        cp "$IMAGE_TEST_DIRECTORY/identity.env" "${destination%% mode=*}"
    fi
done
MOCK
cat >"$test_directory/bin/docker" <<'MOCK'
#!/usr/bin/env bash
touch "$IMAGE_TEST_DIRECTORY/docker-called"
exit 99
MOCK
cat >"$test_directory/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$IMAGE_TEST_DIRECTORY/calls"
[[ "$*" == *"--region $IMAGE_TEST_REGION"* ]] || exit 98
case "$1 $2" in
    'sts get-caller-identity') cat "$IMAGE_TEST_DIRECTORY/account"; exit ;;
    'cloudformation describe-stacks')
        [[ "$3 $4" == "--stack-name morrowpal-$IMAGE_TEST_ENVIRONMENT-ecr" ]] || exit 97
        file=stack ;;
    'ecr describe-repositories'|'ecr describe-images')
        [[ "$3 $4" == '--registry-id 123456789012' ]] || exit 97
        [[ "$6" == "morrowpal/$IMAGE_TEST_ENVIRONMENT/"* ]] || exit 97
        component="${6##*/}"
        case "$component" in
            backend-api|backend-job) tag=build-12-abc1234 ;;
            app) tag=build-29-def5678 ;;
            website) tag=build-13-1234567 ;;
            *) exit 97 ;;
        esac
        if [[ "$2" == describe-repositories ]]; then
            [[ "$5" == --repository-names ]] || exit 97
            file="repository-$component"
        else
            [[ "$5 $7 $8" == "--repository-name --image-ids imageTag=$tag" ]] || exit 97
            file="image-$component"
        fi ;;
    *) printf 'Unexpected AWS operation\n' >&2; exit 99 ;;
esac
[[ "${IMAGE_TEST_API_FAILURE:-}" != "$file" ]] || exit 96
cat "$IMAGE_TEST_DIRECTORY/$file.json"
MOCK
chmod 0700 "$test_directory/bin/"*
export PATH="$test_directory/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION IMAGE_TEST_API_FAILURE
checker="$script_directory/check-replacement-images.sh"
count=0
for environment in staging prod; do
    export IMAGE_TEST_ENVIRONMENT="$environment" IMAGE_TEST_REGION=us-east-1
    [[ "$environment" != prod ]] || export IMAGE_TEST_REGION=us-east-2
    node --input-type=module - "$script_directory/../ec2-image.json" <<'NODE'
import fs from 'node:fs';
const dir=process.env.IMAGE_TEST_DIRECTORY,env=process.env.IMAGE_TEST_ENVIRONMENT,region=process.env.IMAGE_TEST_REGION;
const account='123456789012',prefix=`morrowpal-${env}`,zone=`${region}a`,stack=`${prefix}-ecr`;
const policy=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const save=(name,value)=>fs.writeFileSync(`${dir}/${name}.json`,JSON.stringify(value));
const network={vpcId:'vpc-12345678',subnetId:'subnet-12345678',securityGroupId:'sg-12345678',keyName:env==='prod'?'01':`${prefix}-01`};
const record={schemaVersion:1,environment:env,accountId:account,region,availabilityZone:zone,
    original:{stackName:`${prefix}-ec2`,instanceId:'i-12345678',amiId:'ami-12345678',rootVolumeId:'vol-12345678'},
    candidate:{stackName:`${prefix}-ec2-os-align-01`,instanceId:'i-23456789',amiId:'ami-23456789',rootVolumeId:'vol-23456789',imageName:policy.name},
    data:{volumeId:'vol-34567890',filesystemUuid:'12345678-1234-1234-1234-123456789012',snapshotId:'snap-12345678'},
    publicIp:{allocationId:'eipalloc-12345678',address:'192.0.2.10'},network,
    releases:{backend:{tag:'build-12-abc1234',apiDigest:`sha256:${'a'.repeat(64)}`,jobDigest:`sha256:${'b'.repeat(64)}`},
        app:{tag:'build-29-def5678',digest:`sha256:${'c'.repeat(64)}`},website:{tag:'build-13-1234567',digest:`sha256:${'d'.repeat(64)}`}},
    shutdown:env==='prod'?null:{groupName:`${prefix}-auto-stop`,scheduleName:`${prefix}-auto-stop-nightly`,originalTargetInstanceId:'i-12345678'}};
save('record',record);
const identity={MORROWPAL_ENVIRONMENT:env,MORROWPAL_STACK_PREFIX:prefix,MORROWPAL_EC2_STACK_NAME:record.original.stackName,
    MORROWPAL_AWS_ACCOUNT_ID:account,MORROWPAL_AWS_REGION:region,MORROWPAL_AVAILABILITY_ZONE:zone,
    MORROWPAL_PUBLIC_IPV4:record.publicIp.address,MORROWPAL_VPC_ID:network.vpcId,MORROWPAL_SUBNET_ID:network.subnetId,
    MORROWPAL_SECURITY_GROUP_ID:network.securityGroupId,MORROWPAL_EC2_KEY_NAME:network.keyName};
fs.writeFileSync(`${dir}/identity.env`,Object.entries(identity).map(([k,v])=>`${k}=${JSON.stringify(v)}`).join('\n'));
fs.writeFileSync(`${dir}/account`,account+'\n');
const outputs=[];
for(const [component,key,tag,digest] of [
    ['backend-api','BackendApi',record.releases.backend.tag,record.releases.backend.apiDigest],
    ['backend-job','BackendJob',record.releases.backend.tag,record.releases.backend.jobDigest],
    ['app','App',record.releases.app.tag,record.releases.app.digest],
    ['website','Website',record.releases.website.tag,record.releases.website.digest]]) {
    const name=`morrowpal/${env}/${component}`,uri=`${account}.dkr.ecr.${region}.amazonaws.com/${name}`;
    outputs.push({OutputKey:`${key}RepositoryName`,OutputValue:name},{OutputKey:`${key}RepositoryUri`,OutputValue:uri});
    save(`repository-${component}`,{repositories:[{registryId:account,repositoryName:name,repositoryUri:uri,
        repositoryArn:`arn:aws:ecr:${region}:${account}:repository/${name}`,imageTagMutability:'IMMUTABLE'}]});
    save(`image-${component}`,{imageDetails:[{registryId:account,repositoryName:name,imageTags:[tag,'another-tag'],imageDigest:digest,imageStatus:'ACTIVE'}]});
}
save('stack',{Stacks:[{StackId:`arn:aws:cloudformation:${region}:${account}:stack/${stack}/fixture-id`,StackStatus:'CREATE_COMPLETE',Outputs:outputs}]});
NODE
    before="$(sha256sum "$test_directory/record.json")"
    bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output"
    reject() {
        local file="$test_directory/$1.json" mutation="$2"
        cp "$file" "$test_directory/backup.json"
        jq "$mutation" "$file" >"$test_directory/mutated.json"
        cp "$test_directory/mutated.json" "$file"
        if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail "Accepted $1: $mutation"; fi
        rg -q 'Error:' "$test_directory/output" || fail 'Unexpected validation failure'
        cp "$test_directory/backup.json" "$file"
        count=$((count+1))
    }
    for mutation in '.Stacks=[]' '.Stacks[0].StackId="foreign"' '.Stacks[0].StackStatus="UPDATE_IN_PROGRESS"'; do reject stack "$mutation"; done
    output_index=0
    for component in backend-api backend-job app website; do
        reject stack ".Stacks[0].Outputs[$output_index].OutputValue=\"morrowpal/other/$component\""
        reject stack ".Stacks[0].Outputs[$((output_index+1))].OutputValue=\"wrong-registry\""
        output_index=$((output_index+2))
        for mutation in '.repositories=[]' '.repositories[0].registryId="999999999999"' \
            '.repositories[0].repositoryName="morrowpal/other/component"' '.repositories[0].repositoryUri="wrong-region"' \
            '.repositories[0].repositoryArn="foreign"' '.repositories[0].imageTagMutability="MUTABLE"' \
            '.repositories[0].imageTagMutability="IMMUTABLE_WITH_EXCLUSION"'; do reject "repository-$component" "$mutation"; done
        for mutation in '.imageDetails=[]' '.imageDetails[0].registryId="999999999999"' \
            '.imageDetails[0].repositoryName="morrowpal/other/component"' '.imageDetails[0].imageTags=["latest"]' \
            '.imageDetails[0].imageDigest=("sha256:"+("f"*64))' '.imageDetails[0].imageStatus="ARCHIVED"'; do reject "image-$component" "$mutation"; done
        export IMAGE_TEST_API_FAILURE="image-$component"
        if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Ignored missing image/API error'; fi
        unset IMAGE_TEST_API_FAILURE
        # Older ECR responses can omit imageStatus; the exact tag/digest checks still apply.
        jq 'del(.imageDetails[0].imageStatus)' "$test_directory/image-$component.json" >"$test_directory/change.json"
        cp "$test_directory/change.json" "$test_directory/image-$component.json"
    done
    bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output"
    reject image-backend-job '.imageDetails[0].imageDigest=("sha256:"+("a"*64))'
    [[ "$(sha256sum "$test_directory/record.json")" == "$before" ]] || fail 'Record modified'
    : >"$test_directory/calls"
    for variable in AWS_REGION AWS_DEFAULT_REGION; do
        if env "$variable=us-west-2" bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted Region mismatch'; fi
    done
    reject record '.environment="other"'
    if bash "$checker" >"$test_directory/output" 2>&1; then fail 'Accepted omitted environment'; fi
    if bash "$checker" other "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted invalid environment'; fi
    [[ ! -s "$test_directory/calls" ]] || fail 'Invalid local input called AWS'
    printf '999999999999\n' >"$test_directory/account"
    if bash "$checker" "$environment" "$test_directory/record.json" >"$test_directory/output" 2>&1; then fail 'Accepted wrong caller account'; fi
    [[ "$(wc -l <"$test_directory/calls")" == 1 ]] || fail 'Wrong account continued querying resources'
    [[ ! -e "$test_directory/docker-called" ]] || fail 'Checker called Docker'
    printf '%s release image checks passed.\n' "$environment"
done
printf 'Replacement image tests passed: all four images in both environments and %s mismatches, using only mocked AWS reads.\n' "$count"
