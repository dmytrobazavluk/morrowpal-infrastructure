#!/usr/bin/env bash
set -Eeuo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fixture="$work/infrastructure"
mkdir -p "$fixture/shared/scripts" "$work/bin"
cp "$directory/finish-staging-os-alignment.sh" "$fixture/shared/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/shared/scripts/validate-replacement-record.sh"
printf '%s\n' '{"environment":"staging","accountId":"123456789012","region":"us-east-1","publicIp":{"address":"192.0.2.10"}}' >"$work/record.json"
printf '{}\n' >"$work/production.json"
export FINISH_ACCOUNT_TEST_LOG="$work/calls"
cat >"$work/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FINISH_ACCOUNT_TEST_LOG"
[[ "$1 $2" == 'sts get-caller-identity' ]] || exit 99
printf '999999999999\n'
MOCK
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION
if bash "$fixture/shared/scripts/finish-staging-os-alignment.sh" "$work/record.json" "$work/production.json" staging@example.com >"$work/output" 2>&1; then exit 1; fi
rg -q 'AWS account does not match staging' "$work/output"
[[ "$(wc -l <"$work/calls")" == 1 ]]
printf 'Staging batch rejects caller account mismatch before any cleanup or other resource operation.\n'
