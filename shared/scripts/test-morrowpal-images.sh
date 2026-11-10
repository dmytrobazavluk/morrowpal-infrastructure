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
fixture="$test_directory/infrastructure"
mkdir -p "$fixture/shared/scripts" "$fixture/shared/runtime" "$fixture/environments" \
    "$fixture/build-numbers" "$test_directory/bin" "$test_directory/backend" \
    "$test_directory/frontend" "$test_directory/www"
cp "$script_directory/build-images.sh" "$script_directory/push-images.sh" "$fixture/shared/scripts/"
cp "$repository_directory/shared/runtime/compose.env.j2" "$fixture/shared/runtime/"
cp "$repository_directory/ansible.cfg" "$fixture/"
for environment in prod staging; do
    mkdir "$fixture/environments/$environment"
    cp "$repository_directory/environments/$environment/vars.yml" "$fixture/environments/$environment/"
done
for component in backend app website; do printf '0\n' >"$fixture/build-numbers/$component"; done
export MORROWPAL_TEST_LOG="$test_directory/tools.log"
export MORROWPAL_TEST_PUSHED="$test_directory/pushed"
export MORROWPAL_TEST_REAL_ANSIBLE="$(command -v ansible)"
export MORROWPAL_TEST_ACCOUNT=384078510608
: >"$MORROWPAL_TEST_LOG"
: >"$MORROWPAL_TEST_PUSHED"

cat >"$test_directory/bin/aws" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'aws:%s\n' "$*" >>"$MORROWPAL_TEST_LOG"
case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' "$MORROWPAL_TEST_ACCOUNT" ;;
    'ecr get-login-password') printf 'mock-login\n' ;;
    'ecr describe-images') printf 'sha256:%064d\n' "${MORROWPAL_TEST_DIGEST:-1}" ;;
    'ecr describe-image-scan-findings')
        printf '{"status":"COMPLETE","findings":{"HIGH":%s}}\n' "${MORROWPAL_TEST_HIGH:-0}" ;;
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

push="$fixture/shared/scripts/push-images.sh"
tag="$(cat "$test_directory/BACKEND_TAG")"
snapshot="$(sha256sum "$fixture/build-numbers/"*)"
if "$push" prod backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Prod accepted without confirmation'; fi
if "$push" staging backend "$tag" --confirm-production >"$test_directory/rejected.log" 2>&1; then fail 'Staging accepted production confirmation'; fi
if "$push" qa backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Unknown environment accepted'; fi
if "$push" >"$test_directory/rejected.log" 2>&1; then fail 'Missing environment accepted'; fi
MORROWPAL_TEST_ACCOUNT=000000000000
export MORROWPAL_TEST_ACCOUNT
: >"$MORROWPAL_TEST_LOG"
if "$push" staging backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Wrong account accepted'; fi
if grep -Eq 'ecr|docker:' "$MORROWPAL_TEST_LOG"; then fail 'Wrong account reached image operations'; fi
MORROWPAL_TEST_ACCOUNT=384078510608
export MORROWPAL_TEST_ACCOUNT
: >"$MORROWPAL_TEST_LOG"
if MORROWPAL_TEST_MISSING=true "$push" staging backend "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Missing job image accepted'; fi
if grep -Eq 'get-login-password|docker:.*push ' "$MORROWPAL_TEST_LOG"; then fail 'Missing job image allowed a partial push'; fi

for component in backend app website; do
    case "$component" in backend) variable=BACKEND_TAG ;; app) variable=APP_TAG ;; website) variable=WEBSITE_TAG ;; esac
    tag="$(cat "$test_directory/$variable")"
    : >"$MORROWPAL_TEST_LOG"
    "$push" staging "$component" "$tag" --dry-run >"$test_directory/push.log" 2>&1
    if grep -Eq 'get-login-password|docker:.*(tag |push |login )' "$MORROWPAL_TEST_LOG"; then fail 'Dry run changed images'; fi
    "$push" staging "$component" "$tag" >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    "$push" prod "$component" "$tag" --confirm-production >"$test_directory/push.log" 2>&1 \
        || { cat "$test_directory/push.log" >&2; exit 1; }
    grep -Fq 'morrowpal/staging/' "$MORROWPAL_TEST_LOG"
    grep -Fq 'morrowpal/prod/' "$MORROWPAL_TEST_LOG"
    if grep -Eq 'docker:build|gradle:|flutter:|dart:' "$MORROWPAL_TEST_LOG"; then fail 'Push rebuilt an image'; fi
done
if MORROWPAL_TEST_HIGH=1 "$push" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'High findings accepted'; fi
grep -Fq 'critical or high findings' "$test_directory/rejected.log"
if MORROWPAL_TEST_DIGEST=3 "$push" staging app "$tag" >"$test_directory/rejected.log" 2>&1; then fail 'Digest mismatch accepted'; fi
grep -Fq 'Remote digest does not match' "$test_directory/rejected.log"
[[ "$snapshot" == "$(sha256sum "$fixture/build-numbers/"*)" ]] || fail 'Push changed a counter'
printf 'Component builds, counter locking, guarded pushes, scan gates and digest verification passed.\n'
