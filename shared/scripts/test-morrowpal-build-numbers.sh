#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

reserve() {
    bash -c '
        source "$1"
        morrowpal_reserve_build_number "$2" "$3"
        exit "${4:-0}"
    ' counter-test "$script_directory/morrowpal-publish-config.sh" \
        "$1" "$test_directory" "${2:-0}"
}

assert_counter() {
    [[ "$(cat "$test_directory/build-numbers/$1")" == "$2" ]] \
        || fail "Unexpected $1 counter; expected $2"
}

mkdir "$test_directory/build-numbers"
for component in backend app website; do
    printf '32\n' >"$test_directory/build-numbers/$component"
done

# Keep one publishing process alive until the parent explicitly releases it.
coproc holder {
    bash -c '
        source "$1"
        morrowpal_reserve_build_number backend "$2"
        printf "ready\n"
        read -r release
    ' counter-holder "$script_directory/morrowpal-publish-config.sh" \
        "$test_directory" 2>"$test_directory/holder.log"
}
holder_pid="$holder_PID"
read -r -t 10 ready <&"${holder[0]}" || fail "Counter holder did not start"
[[ "$ready" == ready ]] || fail "Unexpected holder response"

if reserve backend >"$test_directory/blocked.log" 2>&1; then
    fail "Concurrent backend reservation succeeded"
fi
grep -Fq 'Another backend publishing build' "$test_directory/blocked.log" \
    || fail "Concurrent reservation failed for an unexpected reason"
assert_counter backend 33
for component in app website; do
    reserve "$component" 2>"$test_directory/reservation.log"
    assert_counter "$component" 33
done

printf 'release\n' >&"${holder[1]}"
wait "$holder_pid"
holder_pid=""

if reserve backend 7 2>"$test_directory/reservation.log"; then
    fail "Simulated build failure returned success"
else
    [[ "$?" == 7 ]] || fail "Unexpected simulated failure status"
fi
assert_counter backend 34
reserve backend 2>"$test_directory/reservation.log"
assert_counter backend 35
printf 'invalid\n' >"$test_directory/build-numbers/app"
if reserve app >"$test_directory/invalid.log" 2>&1; then
    fail "Invalid counter was accepted"
fi
assert_counter app invalid
if reserve unknown >/dev/null 2>&1; then fail "Unknown component was accepted"; fi

printf 'Build counter increments, failure persistence and component locking passed.\n'
