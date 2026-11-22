#!/usr/bin/env bash

set -Eeuo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/../.." && pwd)"
test_directory="$(mktemp -d)"
holder_pid=""
cleanup() {
    if [[ -n "$holder_pid" ]]; then
        kill "$holder_pid" 2>/dev/null || true
        wait "$holder_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# All state and build tools are isolated. No real counter, image or AWS resource
# is changed by this test, including the production push cases below.
fixture="$test_directory/infrastructure/aws"
mkdir -p "$fixture/shared/scripts" "$fixture/shared/runtime" "$fixture/environments" \
    "$fixture/build-numbers" "$test_directory/bin" "$test_directory/backend" \
    "$test_directory/frontend" "$test_directory/www"
cp "$script_directory/build-images.sh" "$script_directory/deploy-images.sh" "$fixture/shared/scripts/"
# Offline deployment tests must not acquire the live staging maintenance lock.
sed -i "s|/tmp/morrowpal-staging-host-handoff.lock|$test_directory/handoff.lock|g" "$fixture/shared/scripts/deploy-images.sh"
cp "$repository_directory/shared/runtime/compose.env.j2" "$fixture/shared/runtime/"
cp "$repository_directory/shared/runtime/cloudformation.env.j2" "$fixture/shared/runtime/"
cp "$repository_directory/ansible.cfg" "$fixture/"
mkdir "$fixture/shared/playbooks"
cp "$repository_directory/shared/playbooks/deploy.yml" "$fixture/shared/playbooks/"
restore_fixture_vars() {
    local environment="$1"
    # Normal cases use the mock's canonical host; candidate cases opt in below.
    sed "s/^morrowpal_ec2_stack_name:.*/morrowpal_ec2_stack_name: morrowpal-$environment-ec2/" \
        "$repository_directory/environments/$environment/vars.yml" \
        >"$fixture/environments/$environment/vars.yml"
}
for environment in prod staging; do
    mkdir "$fixture/environments/$environment"
    restore_fixture_vars "$environment"
    cp "$repository_directory/environments/$environment/inventory.ini" "$fixture/environments/$environment/"
    touch "$test_directory/morrowpal-$environment-01.pem"
done
for component in backend app website; do printf '0\n' >"$fixture/build-numbers/$component"; done
export MORROWPAL_TEST_LOG="$test_directory/tools.log"
export MORROWPAL_TEST_PUSHED="$test_directory/pushed"
export MORROWPAL_TEST_REAL_ANSIBLE="$(command -v ansible)"
export MORROWPAL_TEST_REAL_INVENTORY="$(command -v ansible-inventory)"
export MORROWPAL_TEST_ACCOUNT=384078510608
export MORROWPAL_TEST_FIXTURE="$fixture"
: >"$MORROWPAL_TEST_LOG"
: >"$MORROWPAL_TEST_PUSHED"

cat >"$test_directory/bin/aws" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'aws:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
service="$1" operation="$2"
shift 2
region="" repository="" stack=""
while (($#)); do
    case "$1" in
        --region) region="$2"; shift ;;
        --repository-name|--repository-names) repository="$2"; shift ;;
        --stack-name) stack="$2"; shift ;;
    esac
    shift
done
case "$region" in
    us-east-1) environment=staging; ip=98.95.17.0; zone=us-east-1a; vpc=vpc-0d3057f78521c530d; subnet=subnet-06f9d6d89b1c17eeb; group=sg-082dc509f3354457a; key=morrowpal-staging-01 ;;
    us-east-2) environment=prod; ip=3.12.65.199; zone=us-east-2c; vpc=vpc-07f1d3ea5b12e44b2; subnet=subnet-098ab1625c79adf3d; group=sg-0103b42f143676fda; key=01 ;;
    *) exit 92 ;;
esac
account=384078510608
profile="arn:aws:iam::$account:instance-profile/morrowpal-$environment-profile"
role="arn:aws:iam::$account:role/morrowpal-$environment-role"
ec2_stack="morrowpal-$environment-ec2"
instance_id=i-test
if [[ "${MORROWPAL_TEST_CANDIDATE:-false}" == true ]]; then ec2_stack="$ec2_stack-os-align-01"; instance_id=i-candidate; fi
case "${MORROWPAL_TEST_BINDING_FAILURE:-}" in
    key) key=wrong-key ;;
    group) group=wrong-group ;;
    subnet) subnet=wrong-subnet ;;
    profile) profile=wrong-profile ;;
    ip) ip=192.0.2.1 ;;
esac
if [[ "${MORROWPAL_TEST_CHANGE_AFTER_SCAN:-false}" == true && -e "$MORROWPAL_TEST_FIXTURE/scanned" ]]; then
    MORROWPAL_TEST_BINDING_FAILURE=environment
fi
case "$service $operation" in
    'sts get-caller-identity') printf '%s\n' "$MORROWPAL_TEST_ACCOUNT" ;;
    'cloudformation describe-stacks')
        case "$stack" in
            *-ec2-access) outputs="$(jq -n --arg profile "$profile" --arg role "$role" '[{OutputKey:"InstanceProfileArn",OutputValue:$profile},{OutputKey:"RoleArn",OutputValue:$role}]')" ;;
            *-public-ip) outputs="$(jq -n --arg ip "$ip" '[{OutputKey:"PublicIp",OutputValue:$ip},{OutputKey:"AllocationId",OutputValue:"eipalloc-test"}]')" ;;
            "$ec2_stack") outputs="$(jq -n --arg id "$instance_id" --arg zone "$zone" '[{OutputKey:"InstanceId",OutputValue:$id},{OutputKey:"AvailabilityZone",OutputValue:$zone}]')" ;;
            *) exit 93 ;;
        esac
        status=CREATE_COMPLETE
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == stack ]]; then status=UPDATE_IN_PROGRESS; fi
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == ec2-stack && "$stack" == "$ec2_stack" ]]; then stack="morrowpal-$environment-ec2-wrong"; fi
        jq -n --arg id "arn:aws:cloudformation:$region:$account:stack/$stack/test" --arg status "$status" \
            --argjson outputs "$outputs" '{Stacks:[{StackId:$id,StackStatus:$status,Outputs:$outputs}]}' ;;
    'iam get-instance-profile')
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == role ]]; then role=wrong-role; fi
        jq -n --arg profile "$profile" --arg role "$role" '{InstanceProfile:{Arn:$profile,Roles:[{Arn:$role}]}}' ;;
    'ec2 describe-instances')
        tag_environment="$environment"; state=running
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == environment ]]; then tag_environment=other; fi
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == stopped ]]; then state=stopped; fi
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == instance-stack ]]; then ec2_stack="morrowpal-$environment-ec2-wrong"; fi
        jq -n --arg id "$instance_id" --arg stack "$ec2_stack" --arg account "$account" --arg ip "$ip" --arg zone "$zone" --arg vpc "$vpc" \
            --arg subnet "$subnet" --arg group "$group" --arg key "$key" --arg profile "$profile" \
            --arg environment "$tag_environment" --arg selected "$environment" --arg state "$state" '
            {Reservations:[{OwnerId:$account,Instances:[{InstanceId:$id,State:{Name:$state},
                PublicIpAddress:$ip,VpcId:$vpc,SubnetId:$subnet,SecurityGroups:[{GroupId:$group}],
                Placement:{AvailabilityZone:$zone},KeyName:$key,IamInstanceProfile:{Arn:$profile},
                Tags:[{Key:"Application",Value:"morrowpal"},{Key:"Environment",Value:$environment},
                    {Key:"Name",Value:("morrowpal-"+$selected+"-01")},
                    {Key:"aws:cloudformation:stack-name",Value:$stack}]}]}]}' ;;
    'ec2 describe-addresses')
        instance="$instance_id"
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == old-ip ]]; then instance=i-test; fi
        if [[ "${MORROWPAL_TEST_BINDING_FAILURE:-}" == association ]]; then instance=i-other; fi
        jq -n --arg ip "$ip" --arg instance "$instance" '{Addresses:[{AllocationId:"eipalloc-test",PublicIp:$ip,InstanceId:$instance}]}' ;;
    'ecr describe-repositories') printf '%s\n' "${MORROWPAL_TEST_MUTABILITY:-IMMUTABLE}" ;;
    'ecr get-login-password') printf 'mock-login\n' ;;
    'ecr describe-images')
        if [[ "${MORROWPAL_TEST_MUTATE_INPUTS:-false}" == true ]]; then
            cp "$MORROWPAL_TEST_FIXTURE/environments/prod/inventory.ini" "$MORROWPAL_TEST_FIXTURE/environments/staging/inventory.ini"
            cp "$MORROWPAL_TEST_FIXTURE/environments/prod/vars.yml" "$MORROWPAL_TEST_FIXTURE/environments/staging/vars.yml"
        fi
        if grep -Fq "/$repository@" "$MORROWPAL_TEST_PUSHED"; then
            printf 'sha256:%064d\n' "${MORROWPAL_TEST_DIGEST:-1}"
        else printf 'ImageNotFoundException\n' >&2; exit 254; fi ;;
    'ecr describe-image-scan-findings')
        touch "$MORROWPAL_TEST_FIXTURE/scanned"
        high="${MORROWPAL_TEST_HIGH:-0}"
        if [[ -n "${MORROWPAL_TEST_HIGH_REPOSITORY:-}" && "$repository" == */"$MORROWPAL_TEST_HIGH_REPOSITORY" ]]; then high=1; fi
        printf '{"status":"COMPLETE","findings":{"HIGH":%s}}\n' "$high" ;;
    *) exit 90 ;;
esac
SH
cat >"$test_directory/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
if [[ "$1" == --config ]]; then shift 2; fi
case "$1" in
    image)
        if [[ "${MORROWPAL_TEST_MISSING:-false}" == true && "$*" == *backend-job* ]]; then exit 1; fi
        if [[ -n "${MORROWPAL_TEST_MISSING_REPOSITORY:-}" && "$*" == *"morrowpal/$MORROWPAL_TEST_MISSING_REPOSITORY:"* ]]; then exit 1; fi
        if [[ "$4" == '{{.Id}}' ]]; then printf 'sha256:%064d\n' 2
        else jq -Rsc 'split("\n") | map(select(length > 0))' "$MORROWPAL_TEST_PUSHED"; fi ;;
    push) printf '%s@sha256:%064d\n' "${2%:*}" 1 >>"$MORROWPAL_TEST_PUSHED" ;;
    login) cat >/dev/null ;;
    info|build|tag) ;;
    *) exit 91 ;;
esac
SH
cat >"$test_directory/bin/git" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
    *--short=7*) printf 'abcdef0\n' ;;
    *status*) ;;
    *) printf 'true\n' ;;
esac
SH
cat >"$test_directory/bin/ansible" <<'SH'
#!/usr/bin/env bash
printf 'ansible:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
exec "$MORROWPAL_TEST_REAL_ANSIBLE" "$@"
SH
cat >"$test_directory/bin/ansible-playbook" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'deploy:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
inventory="" overlay="" release="" check=false
while (($#)); do
    case "$1" in
        --inventory) inventory="$2"; shift ;;
        --extra-vars)
            case "$2" in *@*/vars.yml) overlay="${2#@}" ;; *@*/release.json) release="${2#@}" ;; esac
            shift ;;
        --check) check=true ;;
    esac
    shift
done
[[ -f "$inventory" && -f "$overlay" && -f "$release" ]]
ip="$(awk '$1 == "morrowpal_public_ipv4:" {print $2}' "$overlay")"
"$MORROWPAL_TEST_REAL_INVENTORY" -i "$inventory" --list \
    | jq --exit-status --arg ip "$ip" '._meta.hostvars["01"].ansible_host == $ip' >/dev/null
jq --exit-status '.ansible_connection == "ssh" and .ansible_port == 22' "$release" >/dev/null
cp "$release" "$MORROWPAL_TEST_FIXTURE/last-release.json"
exit "${MORROWPAL_TEST_DEPLOY_FAILURE:-0}"
SH
cat >"$test_directory/bin/flutter" <<'SH'
#!/usr/bin/env bash
printf 'flutter:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
SH
cat >"$test_directory/bin/dart" <<'SH'
#!/usr/bin/env bash
printf 'dart:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
exit "${MORROWPAL_TEST_BUILD_FAILURE:-0}"
SH
cat >"$test_directory/backend/gradlew" <<'SH'
#!/usr/bin/env bash
printf 'gradle:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
if [[ "${MORROWPAL_TEST_HOLD_BUILD:-false}" == true ]]; then
    printf 'ready\n'
    read -r release
fi
exit "${MORROWPAL_TEST_BUILD_FAILURE:-0}"
SH
chmod +x "$test_directory/bin/"* "$test_directory/backend/gradlew"
touch "$test_directory/backend/Dockerfile"
for file in index.html robots.txt sitemap.xml styles.css; do touch "$test_directory/www/$file"; done
mkdir "$test_directory/www/"{assets,privacy,child-safety,notifications}
export PATH="$test_directory/bin:$PATH"

build() {
    local component="$1" variable="$2"
    shift 2
    bash -c '
        builder="$1"; variable="$2"; output="$3"; shift 3
        source "$builder" "$@" || exit $?
        printf "%s\n" "${!variable}" >"$output"
    ' build-test "$fixture/shared/scripts/build-images.sh" "$variable" \
        "$test_directory/$variable" "$component" "$@" >"$test_directory/build.log" 2>&1
}
build backend BACKEND_TAG || { cat "$test_directory/build.log" >&2; exit 1; }
build app APP_TAG 1.1.0 || { cat "$test_directory/build.log" >&2; exit 1; }
build website WEBSITE_TAG || { cat "$test_directory/build.log" >&2; exit 1; }
for component in backend app website; do
    [[ "$(cat "$fixture/build-numbers/$component")" == 1 ]] || fail 'Build did not reserve exactly one number'
done
if grep -Eq '^(aws|ansible):|docker:.*(push|login)' "$MORROWPAL_TEST_LOG"; then
    fail 'Local build accessed AWS, Ansible, or pushed an image'
fi
MORROWPAL_TEST_BUILD_FAILURE=7
export MORROWPAL_TEST_BUILD_FAILURE
if build app APP_TAG 1.1.0; then fail 'Failed app build reported success'; fi
[[ "$(cat "$fixture/build-numbers/app")" == 2 ]] || fail 'Failed build did not consume its number'
unset MORROWPAL_TEST_BUILD_FAILURE

# Exercise locking through the real CLI while the fake Gradle task waits.
coproc holder {
    MORROWPAL_TEST_HOLD_BUILD=true \
        MORROWPAL_IMAGE_TAG_OUTPUT_FILE="$test_directory/BACKEND_TAG" \
        "$fixture/shared/scripts/build-images.sh" backend 2>"$test_directory/holder.log"
}
holder_pid="$holder_PID"
read -r -t 10 ready <&"${holder[0]}" || fail 'Counter holder did not start'
[[ "$ready" == ready ]] || fail 'Unexpected build output'
if build backend BACKEND_TAG; then fail 'Concurrent backend build accepted'; fi
grep -Fq 'Another backend release build' "$test_directory/build.log"
[[ "$(cat "$fixture/build-numbers/backend")" == 2 ]] || fail 'Blocked build consumed a number'
build app APP_TAG 1.1.0 || fail 'Independent app build was blocked'
build website WEBSITE_TAG || fail 'Independent website build was blocked'
printf 'release\n' >&"${holder[1]}"
wait "$holder_pid"
holder_pid=""
if MORROWPAL_TEST_BUILD_FAILURE=7 build backend BACKEND_TAG; then fail 'Failed backend build reported success'; fi
[[ "$(cat "$fixture/build-numbers/backend")" == 3 ]] || fail 'Failed backend build lost its number'
build backend BACKEND_TAG || fail 'Backend lock was not released after failure'
[[ "$(cat "$fixture/build-numbers/backend")" == 4 ]] || fail 'Unexpected backend number'

printf 'invalid\n' >"$fixture/build-numbers/app"
if build app APP_TAG 1.1.0; then fail 'Invalid counter was accepted'; fi
[[ "$(cat "$fixture/build-numbers/app")" == invalid ]] || fail 'Invalid counter was overwritten'
printf '3\n' >"$fixture/build-numbers/app"
preflight_snapshot="$(sha256sum "$fixture/build-numbers/"*)"
for arguments in 'unknown' 'app' 'app bad-version' 'backend unexpected'; do
    read -r -a invalid_arguments <<<"$arguments"
    if "$fixture/shared/scripts/build-images.sh" "${invalid_arguments[@]}" >"$test_directory/rejected.log" 2>&1; then
        fail 'Invalid build arguments accepted'
    fi
done
[[ "$preflight_snapshot" == "$(sha256sum "$fixture/build-numbers/"*)" ]] || fail 'Invalid arguments changed a counter'

deploy="$fixture/shared/scripts/deploy-images.sh"
tag="$(cat "$test_directory/BACKEND_TAG")"
snapshot="$(sha256sum "$fixture/build-numbers/"*)"
if "$deploy" prod backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Prod accepted without confirmation'; fi
if "$deploy" staging backend "$tag" --confirm-production >"$test_directory/rejected.log" 2>&1; then fail 'Staging accepted production confirmation'; fi
if "$deploy" qa backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Unknown environment accepted'; fi
if "$deploy" >"$test_directory/rejected.log" 2>&1; then fail 'Missing environment accepted'; fi
for option in --inventory --extra-vars --limit; do
    if "$deploy" staging backend "$tag" "$option" wrong >"$test_directory/rejected.log" 2>&1; then fail 'Ansible override accepted'; fi
done
if AWS_REGION=us-west-2 "$deploy" staging backend "$tag" --dry-run >"$test_directory/rejected.log" 2>&1; then fail 'Wrong Region accepted'; fi
if ANSIBLE_INVENTORY=wrong "$deploy" staging backend "$tag" --dry-run >"$test_directory/rejected.log" 2>&1; then fail 'Ambient inventory override accepted'; fi
cp "$fixture/environments/prod/inventory.ini" "$fixture/environments/staging/inventory.ini"
if "$deploy" staging backend "$tag" --dry-run >"$test_directory/rejected.log" 2>&1; then fail 'Mixed inventory accepted'; fi
cp "$repository_directory/environments/staging/inventory.ini" "$fixture/environments/staging/inventory.ini"
cp "$fixture/environments/prod/vars.yml" "$fixture/environments/staging/vars.yml"
if "$deploy" staging backend "$tag" --dry-run >"$test_directory/rejected.log" 2>&1; then fail 'Mixed overlay accepted'; fi
restore_fixture_vars staging
for binding in environment stack stopped role profile ip association group subnet key; do
    : >"$MORROWPAL_TEST_LOG"
    if MORROWPAL_TEST_BINDING_FAILURE="$binding" "$deploy" staging backend "$tag" --dry-run \
        >"$test_directory/rejected.log" 2>&1; then fail "Mismatched $binding accepted"; fi
    if grep -Eq 'get-login-password|docker:.*push |deploy:' "$MORROWPAL_TEST_LOG"; then fail 'Invalid binding reached a write'; fi
done
MORROWPAL_TEST_ACCOUNT=000000000000
export MORROWPAL_TEST_ACCOUNT
: >"$MORROWPAL_TEST_LOG"
if "$deploy" staging backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Wrong account accepted'; fi
if grep -Eq 'ecr|docker:' "$MORROWPAL_TEST_LOG"; then fail 'Wrong account reached image operations'; fi
MORROWPAL_TEST_ACCOUNT=384078510608
export MORROWPAL_TEST_ACCOUNT
: >"$MORROWPAL_TEST_LOG"
if MORROWPAL_TEST_MISSING=true "$deploy" staging backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Missing job image accepted'; fi
if grep -Eq 'get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Missing job image allowed a partial push'; fi

# A fresh host needs every component tag in the same playbook invocation.
backend_tag="$(cat "$test_directory/BACKEND_TAG")"
app_tag="$(cat "$test_directory/APP_TAG")"
website_tag="$(cat "$test_directory/WEBSITE_TAG")"
initial_tags=("$backend_tag" "$app_tag" "$website_tag")
: >"$MORROWPAL_TEST_LOG"
if "$deploy" staging initial "$backend_tag" "$app_tag" >"$test_directory/rejected.log" 2>&1; then fail 'Initial deployment accepted missing website tag'; fi
if "$deploy" staging initial "$backend_tag" invalid "$website_tag" >"$test_directory/rejected.log" 2>&1; then fail 'Initial deployment accepted malformed app tag'; fi
if "$deploy" prod initial "${initial_tags[@]}" >"$test_directory/rejected.log" 2>&1; then fail 'Initial production deployment omitted confirmation'; fi
[[ ! -s "$MORROWPAL_TEST_LOG" ]] || fail 'Invalid initial arguments accessed tools'
"$deploy" staging initial "${initial_tags[@]}" --dry-run >"$test_directory/push.log" 2>&1
if grep -Eq 'deploy:|get-login-password|docker:.*(tag |push |login )' "$MORROWPAL_TEST_LOG"; then fail 'Initial dry run mutated resources'; fi
: >"$MORROWPAL_TEST_LOG"
if "$deploy" staging initial "${initial_tags[@]}" --check >"$test_directory/rejected.log" 2>&1; then fail 'Initial check accepted unpublished images'; fi
if grep -Eq 'deploy:|get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Initial check published missing images'; fi
: >"$MORROWPAL_TEST_LOG"
if MORROWPAL_TEST_MISSING_REPOSITORY=website "$deploy" staging initial "${initial_tags[@]}" >"$test_directory/rejected.log" 2>&1; then fail 'Initial deployment accepted missing website image'; fi
if grep -Eq 'deploy:|get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Initial image preflight allowed partial publication'; fi
: >"$MORROWPAL_TEST_LOG"
if MORROWPAL_TEST_HIGH_REPOSITORY=website "$deploy" staging initial "${initial_tags[@]}" >"$test_directory/rejected.log" 2>&1; then fail 'Initial deployment accepted website scan failure'; fi
if grep -Fq 'deploy:' "$MORROWPAL_TEST_LOG"; then fail 'Initial scan failure reached host'; fi
: >"$MORROWPAL_TEST_LOG"
: >"$MORROWPAL_TEST_PUSHED"
"$deploy" staging initial "${initial_tags[@]}" >"$test_directory/push.log" 2>&1 \
    || { cat "$test_directory/push.log" >&2; exit 1; }
[[ "$(grep -c '^deploy:' "$MORROWPAL_TEST_LOG")" == 1 ]] || fail 'Initial deployment did not use one playbook invocation'
[[ "$(grep -c 'docker:.*push ' "$MORROWPAL_TEST_LOG")" == 4 ]] || fail 'Initial deployment did not publish four images'
for repository in backend-api backend-job app website; do
    case "$repository" in backend-*) expected_tag="$backend_tag" ;; app) expected_tag="$app_tag" ;; website) expected_tag="$website_tag" ;; esac
    grep -Fq "morrowpal/staging/$repository:$expected_tag" "$MORROWPAL_TEST_LOG" || fail "Wrong initial tag for $repository"
    grep -Fq -- "--repository-name morrowpal/staging/$repository --image-id imageTag=$expected_tag" "$MORROWPAL_TEST_LOG" || fail "Wrong scan tag for $repository"
done
jq --exit-status --arg backend "$backend_tag" --arg app "$app_tag" --arg website "$website_tag" '
    .morrowpal_image_tag == $backend and .morrowpal_app_image_tag == $app
    and .morrowpal_website_image_tag == $website
' "$fixture/last-release.json" >/dev/null || fail 'Initial deployment omitted or mixed component tags'
[[ "$(tail -1 "$MORROWPAL_TEST_LOG")" == deploy:* ]] || fail 'Initial host action preceded image validation'
: >"$MORROWPAL_TEST_LOG"
"$deploy" staging initial "${initial_tags[@]}" --check --diff >"$test_directory/push.log" 2>&1
grep -Eq '^deploy:.*--check.*--diff' "$MORROWPAL_TEST_LOG" || fail 'Initial check omitted Ansible preview flags'
if grep -Eq 'get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Initial check republished images'; fi
"$deploy" prod initial "${initial_tags[@]}" --confirm-production --dry-run >"$test_directory/push.log" 2>&1
: >"$MORROWPAL_TEST_PUSHED"

for component in backend app website; do
    case "$component" in backend) variable=BACKEND_TAG ;; app) variable=APP_TAG ;; website) variable=WEBSITE_TAG ;; esac
    tag="$(cat "$test_directory/$variable")"
    : >"$MORROWPAL_TEST_LOG"
    "$deploy" staging "$component" "$tag" --dry-run >"$test_directory/push.log" 2>&1
    if grep -Eq 'deploy:|get-login-password|docker:.*(tag |push |login )' "$MORROWPAL_TEST_LOG"; then fail 'Dry run changed images'; fi
    "$deploy" staging "$component" "$tag" >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    grep -Fq 'deploy:' "$MORROWPAL_TEST_LOG"
    [[ "$(tail -1 "$MORROWPAL_TEST_LOG")" == deploy:* ]] || fail 'Host action ran before image checks completed'
    before_check_pushes="$(grep -c 'docker:.*push ' "$MORROWPAL_TEST_LOG" || true)"
    "$deploy" staging "$component" "$tag" --check --diff >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    [[ "$before_check_pushes" == "$(grep -c 'docker:.*push ' "$MORROWPAL_TEST_LOG" || true)" ]] || fail 'Check mode pushed images'
    grep -Eq '^deploy:.*--check.*--diff' "$MORROWPAL_TEST_LOG"
    "$deploy" prod "$component" "$tag" --confirm-production >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    grep -Fq 'morrowpal/staging/' "$MORROWPAL_TEST_LOG"
    grep -Fq 'morrowpal/prod/' "$MORROWPAL_TEST_LOG"
    if grep -Eq 'docker:build|gradle:|flutter:|dart:' "$MORROWPAL_TEST_LOG"; then fail 'Push rebuilt an image'; fi
done
: >"$MORROWPAL_TEST_LOG"
tag="$app_tag"
for environment in staging prod; do
    vars="$fixture/environments/$environment/vars.yml"
    sed "s/^morrowpal_ec2_stack_name:.*/morrowpal_ec2_stack_name: morrowpal-$environment-ec2-os-align-01/" \
        "$repository_directory/environments/$environment/vars.yml" >"$vars"
    confirmation=()
    [[ "$environment" != prod ]] || confirmation=(--confirm-production)
    : >"$MORROWPAL_TEST_LOG"
    MORROWPAL_TEST_CANDIDATE=true "$deploy" "$environment" app "$tag" "${confirmation[@]}" --dry-run >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    grep -Fq -- "--stack-name morrowpal-$environment-ec2-os-align-01" "$MORROWPAL_TEST_LOG" || fail 'Deployment did not resolve active candidate stack'
    grep -Fq -- '--instance-ids i-candidate' "$MORROWPAL_TEST_LOG" || fail 'Deployment did not resolve candidate instance'
    for binding in ec2-stack instance-stack old-ip; do
        : >"$MORROWPAL_TEST_LOG"
        if MORROWPAL_TEST_CANDIDATE=true MORROWPAL_TEST_BINDING_FAILURE="$binding" \
            "$deploy" "$environment" app "$tag" "${confirmation[@]}" >"$test_directory/rejected.log" 2>&1; then fail "Candidate accepted $binding"; fi
        if grep -Eq 'deploy:|get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Candidate mismatch reached a write'; fi
    done
    : >"$MORROWPAL_TEST_LOG"
    MORROWPAL_TEST_CANDIDATE=true "$deploy" "$environment" app "$tag" "${confirmation[@]}" >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    grep -Fq 'deploy:' "$MORROWPAL_TEST_LOG" || fail 'Validated candidate was not deployed'
    for invalid_stack in "morrowpal-other-ec2" "morrowpal-$environment-ecr" ''; do
        sed "s/^morrowpal_ec2_stack_name:.*/morrowpal_ec2_stack_name: $invalid_stack/" \
            "$repository_directory/environments/$environment/vars.yml" >"$vars"
        : >"$MORROWPAL_TEST_LOG"
        if "$deploy" "$environment" app "$tag" "${confirmation[@]}" >"$test_directory/rejected.log" 2>&1; then fail 'Invalid deployment stack name accepted'; fi
        if grep -Eq '^aws:|^deploy:' "$MORROWPAL_TEST_LOG"; then fail 'Invalid stack name reached AWS or host'; fi
    done
    restore_fixture_vars "$environment"
done
: >"$MORROWPAL_TEST_LOG"
if MORROWPAL_TEST_HIGH=1 "$deploy" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'High findings accepted'; fi
grep -Fq 'critical or high findings' "$test_directory/rejected.log"
if grep -Fq 'deploy:' "$MORROWPAL_TEST_LOG"; then fail 'Scan failure reached Ansible'; fi
if MORROWPAL_TEST_DIGEST=3 "$deploy" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Digest mismatch accepted'; fi
grep -Fq 'Published tag does not match' "$test_directory/rejected.log"
if MORROWPAL_TEST_MUTABILITY=MUTABLE "$deploy" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Mutable release repository accepted'; fi
: >"$MORROWPAL_TEST_LOG"
rm -f "$fixture/scanned"
if MORROWPAL_TEST_CHANGE_AFTER_SCAN=true "$deploy" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Changed target reached deployment'; fi
if grep -Fq 'deploy:' "$MORROWPAL_TEST_LOG"; then fail 'Changed target reached Ansible'; fi
: >"$MORROWPAL_TEST_LOG"
if MORROWPAL_TEST_DEPLOY_FAILURE=9 "$deploy" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Ansible failure was hidden'; fi
"$deploy" staging app "$tag" >"$test_directory/push.log" 2>&1
if grep -Eq 'get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Retry republished an existing image'; fi
MORROWPAL_TEST_MISSING=true "$deploy" staging backend "$(cat "$test_directory/BACKEND_TAG")" \
    >"$test_directory/push.log" 2>&1 || fail 'Published image could not be deployed without its local copy'
MORROWPAL_TEST_MUTATE_INPUTS=true "$deploy" staging app "$tag" >"$test_directory/push.log" 2>&1 \
    || fail 'Deployment did not preserve its validated snapshots'
restore_fixture_vars staging
cp "$repository_directory/environments/staging/inventory.ini" "$fixture/environments/staging/inventory.ini"
: >"$MORROWPAL_TEST_LOG"
"$deploy" staging infrastructure --check --diff >"$test_directory/push.log" 2>&1
if grep -Eq 'aws:ecr|docker:' "$MORROWPAL_TEST_LOG"; then fail 'Infrastructure-only check touched images'; fi
[[ "$snapshot" == "$(sha256sum "$fixture/build-numbers/"*)" ]] || fail 'Push changed a counter'
printf 'Component builds, target binding, guarded publication and deployment passed.\n'
