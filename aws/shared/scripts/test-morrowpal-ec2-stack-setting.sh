#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/../.." && pwd)"
test_directory="$(mktemp -d)"
trap 'rm -rf -- "$test_directory"' EXIT
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Only public configuration fixtures and stubbed Ansible commands are used.
fixture="$test_directory/infrastructure"
mkdir -p "$fixture/scripts" "$fixture/shared/playbooks" \
    "$fixture/environments/"{prod,staging} "$test_directory/bin"
cp "$repository_directory/scripts/validate-environments.sh" "$fixture/scripts/"
cp "$repository_directory/ansible.cfg" "$fixture/"
cp "$repository_directory/shared/playbooks/"*.yml "$fixture/shared/playbooks/"
for environment in prod staging; do
    cp "$repository_directory/environments/$environment/"{vars.yml,inventory.ini} "$fixture/environments/$environment/"
done
for tool in ansible ansible-inventory ansible-playbook; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$test_directory/bin/$tool"
    chmod 0700 "$test_directory/bin/$tool"
done
export PATH="$test_directory/bin:$PATH"
validator="$fixture/scripts/validate-environments.sh"
"$validator" >"$test_directory/output"

for environment in prod staging; do
    vars="$fixture/environments/$environment/vars.yml"
    original="$repository_directory/environments/$environment/vars.yml"
    for suffix in '' '-os-align-01'; do
        sed "s/^morrowpal_ec2_stack_name:.*/morrowpal_ec2_stack_name: morrowpal-$environment-ec2$suffix/" "$original" >"$vars"
        "$validator" >"$test_directory/output" || fail "Valid $environment stack name rejected"
    done
    other_environment=prod
    [[ "$environment" != prod ]] || other_environment=staging
    printf -v long_suffix '%0128d' 0
    for invalid in '' "morrowpal-$other_environment-ec2" "morrowpal-$environment-ecr" \
        "morrowpal-$environment-ec2-" "morrowpal-$environment-ec2--candidate" \
        "morrowpal-$environment-ec2-bad_name" "morrowpal-$environment-ec2 candidate" \
        "morrowpal-$environment-ec2-$long_suffix"; do
        sed "s/^morrowpal_ec2_stack_name:.*/morrowpal_ec2_stack_name: $invalid/" "$original" >"$vars"
        if "$validator" >"$test_directory/output" 2>&1; then fail 'Invalid EC2 stack name accepted'; fi
        grep -Fq 'EC2 stack name must select' "$test_directory/output" || fail 'Wrong validation failure'
    done
    sed '/^morrowpal_ec2_stack_name:/d' "$original" >"$vars"
    if "$validator" >"$test_directory/output" 2>&1; then fail 'Missing stack setting accepted'; fi
    grep -Fq "Missing required key 'morrowpal_ec2_stack_name'" "$test_directory/output" || fail 'Missing setting failed for wrong reason'
    cp "$original" "$vars"
done
printf 'Environment-bound EC2 stack setting validation passed.\n'
